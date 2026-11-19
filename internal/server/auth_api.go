package server

import (
	"encoding/json"
	"io"
	"log"
	"net/http"
	"strings"

	"github.com/bobo/KOTV/internal/auth"
	"github.com/bobo/KOTV/internal/grouppolicy"
	"github.com/bobo/KOTV/internal/usage"
)

func (s *Server) handleAuthStatus(w http.ResponseWriter, r *http.Request) {
	writeJSON(w, http.StatusOK, map[string]any{
		"ok":              true,
		"remoteAuth":      auth.RemoteAuthEnabled(),
		"allowRegister":   auth.AllowRegister(),
		"requireApproval": auth.RequireApproval(),
		"authRequired":    loginRequired(r),
		"remoteAccess":    remoteAccessAllowed(r),
		// 本机静态/原生免登管理；Flutter Web 与远端须管理员登录。
		"adminRequired": !isLocalNative(r),
		"loopback":      isLoopbackRequest(r),
		"webClient":     isWebClient(r),
	})
}

func (s *Server) handleAuthLogin(w http.ResponseWriter, r *http.Request) {
	body, reply, ok := readLoginForm(w, r)
	if !ok {
		return
	}
	tok, user, err := auth.Login(body.Username, body.Password)
	if !isLoopbackRequest(r) {
		result := "成功"
		if err != nil {
			result = "失败"
		}
		log.Printf("远端登录%s: 用户 %s，来自 %s（%s）", result, strings.TrimSpace(body.Username), r.RemoteAddr, clientLabel(r))
	}
	uid := ""
	if err == nil {
		uid = user.ID
	}
	usage.RecordLogin(body.Username, uid, err == nil, r)
	if err != nil {
		writeAPIError(w, http.StatusUnauthorized, err.Error())
		return
	}
	// 设备数 / 会话数限额
	pol := grouppolicy.Resolve(&user)
	if db := s.adminDB(); db != nil {
		if lim := pol.DeviceLimit(); lim > 0 {
			cid := strings.TrimSpace(r.Header.Get("X-Kotv-Client-Id"))
			n, _ := db.CountAuthDevices(user.ID)
			known := false
			if cid != "" {
				devs, _ := db.ListAuthDevices(user.ID)
				for _, d := range devs {
					if d["clientId"] == cid {
						known = true
						break
					}
				}
			}
			if !known && n >= lim {
				_ = auth.ForceLogout(user.ID)
				usage.Record(usage.FromRequest(r, &user), "policy_deny", "device", "", "设备数超限", false, "maxDevices", 0)
				writeAPIError(w, http.StatusForbidden, "绑定设备数已达上限")
				return
			}
		}
		if lim := pol.SessionLimit(); lim > 0 {
			_ = db.TrimAuthTokensKeepNewest(user.ID, lim)
		}
	}
	usage.TouchDevice(&user, r)
	writeSealed(w, reply, map[string]any{
		"ok":    true,
		"token": tok,
		"user":  user.Public(),
	})
}

func (s *Server) handleAuthRegister(w http.ResponseWriter, r *http.Request) {
	body, reply, ok := readLoginForm(w, r)
	if !ok {
		return
	}
	user, err := auth.RegisterWithInvite(body.Username, body.Password, body.InviteCode)
	if err != nil {
		writeAPIError(w, http.StatusBadRequest, err.Error())
		return
	}
	writeSealed(w, reply, map[string]any{"ok": true, "user": user.Public()})
}

type loginForm struct {
	Username   string `json:"username"`
	Password   string `json:"password"`
	InviteCode string `json:"inviteCode"`
}

func readLoginForm(w http.ResponseWriter, r *http.Request) (loginForm, *auth.SealReply, bool) {
	var body loginForm
	if rejectUnlessPost(w, r) {
		return body, nil, false
	}
	if !remoteAccessAllowed(r) {
		writeAPIError(w, http.StatusForbidden, "未开启远端鉴权")
		return body, nil, false
	}
	reply, ok := readCredentials(w, r, &body)
	return body, reply, ok
}

// readCredentials 读带密码的请求体。只收客户端用引擎身份公钥加密的 {"sealed":…}，
// 返回的 SealReply 供 writeSealed 加密回复。
func readCredentials(w http.ResponseWriter, r *http.Request, dst any) (*auth.SealReply, bool) {
	var env struct {
		Sealed *auth.Sealed `json:"sealed"`
	}
	if err := json.NewDecoder(io.LimitReader(r.Body, 1<<20)).Decode(&env); err != nil || env.Sealed == nil {
		writeAPIError(w, http.StatusBadRequest, "账号密码需加密传输，请升级客户端")
		return nil, false
	}
	plain, reply, err := auth.OpenSealed(*env.Sealed, r.URL.Path)
	if err != nil {
		writeAPIError(w, http.StatusBadRequest, err.Error())
		return nil, false
	}
	if err := json.Unmarshal(plain, dst); err != nil {
		writeAPIError(w, http.StatusBadRequest, "请求格式错误")
		return nil, false
	}
	return reply, true
}

// writeSealed 加密回复 readCredentials 读到的请求。
func writeSealed(w http.ResponseWriter, reply *auth.SealReply, v map[string]any) {
	plain, _ := json.Marshal(v)
	writeJSON(w, http.StatusOK, map[string]any{"ok": true, "sealed": reply.Seal(plain)})
}

func (s *Server) handleAuthLogout(w http.ResponseWriter, r *http.Request) {
	if rejectUnlessPost(w, r) {
		return
	}
	// 作废 token 前先释放该用户运行时（与 session/leave 同口径，幂等）。
	if api := s.content(); api != nil && authUserFrom(r.Context()) != nil {
		_ = api.APISessionLeave()
	}
	auth.Logout(auth.BearerFromHeader(r.Header.Get("Authorization")))
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

func (s *Server) handleAuthMe(w http.ResponseWriter, r *http.Request) {
	u := authUserFrom(r.Context())
	if u == nil {
		// 本机原生未登录：机主视图，供用户管理免登录。Web（含本机浏览器）必须登录。
		if isLocalNative(r) {
			writeJSON(w, http.StatusOK, map[string]any{
				"ok":    true,
				"local": true,
				"user": map[string]any{
					"id":                 "",
					"username":           "本机",
					"role":               auth.RoleAdmin,
					"mustChangePassword": false,
				},
			})
			return
		}
		writeAPIError(w, http.StatusUnauthorized, "需要登录")
		return
	}
	out := map[string]any{"ok": true, "user": u.Public()}
	if !isLocalNative(r) {
		// 远端 / Web 客户端自己拼引擎媒体地址（海报相对路径等）时带上它。
		out["mediaKey"] = auth.MediaKey()
	}
	writeJSON(w, http.StatusOK, out)
}

func (s *Server) handleAuthPassword(w http.ResponseWriter, r *http.Request) {
	if rejectUnlessPost(w, r) {
		return
	}
	u := authUserFrom(r.Context())
	if u == nil {
		writeAPIError(w, http.StatusUnauthorized, "需要登录")
		return
	}
	var body struct {
		OldPassword string `json:"oldPassword"`
		NewPassword string `json:"newPassword"`
	}
	reply, ok := readCredentials(w, r, &body)
	if !ok {
		return
	}
	keep := auth.BearerFromHeader(r.Header.Get("Authorization"))
	if err := auth.ChangePassword(u.ID, keep, body.OldPassword, body.NewPassword); err != nil {
		writeAPIError(w, http.StatusBadRequest, err.Error())
		return
	}
	writeSealed(w, reply, map[string]any{"ok": true})
}

func (s *Server) handleAdminUsers(w http.ResponseWriter, r *http.Request) {
	switch r.Method {
	case http.MethodGet:
		list := auth.ListUsers()
		out := make([]map[string]any, 0, len(list))
		for _, u := range list {
			out = append(out, u.Public())
		}
		writeJSON(w, http.StatusOK, map[string]any{
			"ok":              true,
			"users":           out,
			"remoteAuth":      auth.RemoteAuthEnabled(),
			"allowRegister":   auth.AllowRegister(),
			"requireApproval": auth.RequireApproval(),
		})
	case http.MethodPost:
		var body struct {
			Username string `json:"username"`
			Password string `json:"password"`
			Role     string `json:"role"`
			GroupID  string `json:"groupId"`
		}
		reply, ok := readCredentials(w, r, &body)
		if !ok {
			return
		}
		u, err := auth.CreateUser(body.Username, body.Password, body.Role)
		if err != nil {
			writeAPIError(w, http.StatusBadRequest, err.Error())
			return
		}
		if gid := strings.TrimSpace(body.GroupID); gid != "" {
			_ = auth.SetUserGroup(u.ID, gid)
			if nu := auth.GetUser(u.ID); nu != nil {
				u = *nu
			}
		}
		writeSealed(w, reply, map[string]any{"ok": true, "user": u.Public()})
	default:
		writeAPIError(w, http.StatusMethodNotAllowed, "method not allowed")
	}
}

func (s *Server) handleAdminUserAction(w http.ResponseWriter, r *http.Request) {
	path := strings.TrimPrefix(r.URL.Path, "/api/v1/admin/users/")
	parts := strings.Split(strings.Trim(path, "/"), "/")
	if len(parts) == 0 || parts[0] == "" {
		writeAPIError(w, http.StatusBadRequest, "missing user id")
		return
	}
	id := parts[0]
	action := ""
	if len(parts) > 1 {
		action = parts[1]
	}
	switch {
	case r.Method == http.MethodDelete && action == "":
		uname := ""
		if u := auth.GetUser(id); u != nil {
			uname = u.Username
		}
		if err := auth.DeleteUser(id); err != nil {
			writeAPIError(w, http.StatusBadRequest, err.Error())
			return
		}
		if s.contentAPI != nil {
			s.contentAPI.PurgeUserData(id, uname)
		}
		writeJSON(w, http.StatusOK, map[string]any{"ok": true})
	case r.Method == http.MethodPost && action == "enable":
		if err := auth.SetEnabled(id, true); err != nil {
			writeAPIError(w, http.StatusBadRequest, err.Error())
			return
		}
		writeJSON(w, http.StatusOK, map[string]any{"ok": true})
	case r.Method == http.MethodPost && action == "disable":
		if err := auth.SetEnabled(id, false); err != nil {
			writeAPIError(w, http.StatusBadRequest, err.Error())
			return
		}
		writeJSON(w, http.StatusOK, map[string]any{"ok": true})
	case r.Method == http.MethodPost && action == "password":
		var body struct {
			Password string `json:"password"`
		}
		reply, ok := readCredentials(w, r, &body)
		if !ok {
			return
		}
		if err := auth.ResetPassword(id, body.Password); err != nil {
			writeAPIError(w, http.StatusBadRequest, err.Error())
			return
		}
		writeSealed(w, reply, map[string]any{"ok": true})
	case r.Method == http.MethodPost && action == "group":
		var body struct {
			GroupID string `json:"groupId"`
		}
		_ = json.NewDecoder(io.LimitReader(r.Body, 1<<20)).Decode(&body)
		if err := auth.SetUserGroup(id, body.GroupID); err != nil {
			writeAPIError(w, http.StatusBadRequest, err.Error())
			return
		}
		writeJSON(w, http.StatusOK, map[string]any{"ok": true})
	case r.Method == http.MethodPost && action == "role":
		var body struct {
			Role string `json:"role"`
		}
		_ = json.NewDecoder(io.LimitReader(r.Body, 1<<20)).Decode(&body)
		if err := auth.SetUserRole(id, body.Role); err != nil {
			writeAPIError(w, http.StatusBadRequest, err.Error())
			return
		}
		writeJSON(w, http.StatusOK, map[string]any{"ok": true})
	case r.Method == http.MethodPost && action == "logout":
		_ = auth.ForceLogout(id)
		if kicker, ok := s.contentAPI.(interface{ AdminKickUser(string) }); ok {
			kicker.AdminKickUser(id)
		}
		writeJSON(w, http.StatusOK, map[string]any{"ok": true})
	case r.Method == http.MethodGet && action == "devices":
		db := s.adminDB()
		if db == nil {
			writeAPIError(w, http.StatusInternalServerError, "db unavailable")
			return
		}
		list, err := db.ListAuthDevices(id)
		if err != nil {
			writeAPIError(w, http.StatusInternalServerError, err.Error())
			return
		}
		writeJSON(w, http.StatusOK, map[string]any{"ok": true, "devices": list})
	case r.Method == http.MethodDelete && action == "devices":
		cid := strings.TrimSpace(r.URL.Query().Get("clientId"))
		if cid == "" {
			writeAPIError(w, http.StatusBadRequest, "missing clientId")
			return
		}
		if db := s.adminDB(); db != nil {
			_ = db.DeleteAuthDevice(id, cid)
		}
		writeJSON(w, http.StatusOK, map[string]any{"ok": true})
	case r.Method == http.MethodPost && action == "approve":
		if db := s.adminDB(); db != nil {
			_ = db.SetAuthUserStatus(id, "active")
		}
		_ = auth.SetEnabled(id, true)
		writeJSON(w, http.StatusOK, map[string]any{"ok": true})
	default:
		writeAPIError(w, http.StatusBadRequest, "unknown action")
	}
}

func (s *Server) handleAdminSettings(w http.ResponseWriter, r *http.Request) {
	if rejectUnlessPost(w, r) {
		return
	}
	var body struct {
		RemoteAuth      *bool `json:"remoteAuth"`
		AllowRegister   *bool `json:"allowRegister"`
		RequireApproval *bool `json:"requireApproval"`
	}
	_ = json.NewDecoder(io.LimitReader(r.Body, 1<<20)).Decode(&body)
	if body.RemoteAuth != nil {
		_ = auth.SetRemoteAuth(*body.RemoteAuth)
	}
	if body.AllowRegister != nil {
		_ = auth.SetAllowRegister(*body.AllowRegister)
	}
	if body.RequireApproval != nil {
		_ = auth.SetRequireApproval(*body.RequireApproval)
	}
	// 开启开放注册时默认打开审批，避免无人审核的自助账号直接可用。
	if body.AllowRegister != nil && *body.AllowRegister && body.RequireApproval == nil && !auth.RequireApproval() {
		_ = auth.SetRequireApproval(true)
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"ok":              true,
		"remoteAuth":      auth.RemoteAuthEnabled(),
		"allowRegister":   auth.AllowRegister(),
		"requireApproval": auth.RequireApproval(),
	})
}
