package server

import (
	"encoding/json"
	"io"
	"net"
	"net/http"
	"strings"

	"github.com/bobo/KOTV/internal/auth"
	"github.com/bobo/KOTV/internal/hostclient"
)

func isLoopbackRequest(r *http.Request) bool {
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		host = r.RemoteAddr
	}
	ip := net.ParseIP(host)
	return ip != nil && ip.IsLoopback()
}

func authRequiredFor(r *http.Request) bool {
	if !auth.RemoteAuthEnabled() {
		return false
	}
	// 本机无 token 可免密调试；带了 token 则仍校验。
	if isLoopbackRequest(r) && auth.BearerFromHeader(r.Header.Get("Authorization")) == "" {
		return false
	}
	return true
}

func publicAuthPath(path string) bool {
	switch path {
	case "/api/v1/health",
		"/api/v1/auth/login",
		"/api/v1/auth/register",
		"/api/v1/auth/status":
		return true
	default:
		return false
	}
}

// withAuth 远端鉴权中间件；成功后绑定 userId。
func (s *Server) withAuth(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodOptions {
			writeJSON(w, http.StatusOK, map[string]any{"ok": true})
			return
		}
		need := authRequiredFor(r) && !publicAuthPath(r.URL.Path)
		tok := auth.BearerFromHeader(r.Header.Get("Authorization"))
		if need {
			if tok == "" {
				writeAPIError(w, http.StatusUnauthorized, "需要登录")
				return
			}
			u, err := auth.LookupToken(tok)
			if err != nil {
				writeAPIError(w, http.StatusUnauthorized, err.Error())
				return
			}
			done := hostclient.EnterBoth(clientIDFromRequest(r), u.ID)
			defer done()
			r = r.WithContext(withAuthUser(r.Context(), u))
			next(w, r)
			return
		}
		if tok != "" {
			if u, err := auth.LookupToken(tok); err == nil {
				done := hostclient.EnterBoth(clientIDFromRequest(r), u.ID)
				defer done()
				r = r.WithContext(withAuthUser(r.Context(), u))
				next(w, r)
				return
			}
		}
		done := hostclient.Enter(clientIDFromRequest(r))
		defer done()
		next(w, r)
	}
}

func (s *Server) requireAdmin(next http.HandlerFunc) http.HandlerFunc {
	return s.withAuth(func(w http.ResponseWriter, r *http.Request) {
		u := authUserFrom(r.Context())
		if u == nil || u.Role != auth.RoleAdmin {
			writeAPIError(w, http.StatusForbidden, "需要管理员")
			return
		}
		next(w, r)
	})
}

func (s *Server) handleAuthStatus(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodOptions {
		writeJSON(w, http.StatusOK, map[string]any{"ok": true})
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"ok":            true,
		"remoteAuth":    auth.RemoteAuthEnabled(),
		"allowRegister": auth.AllowRegister(),
		"authRequired":  authRequiredFor(r),
	})
}

func (s *Server) handleAuthLogin(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodOptions {
		writeJSON(w, http.StatusOK, map[string]any{"ok": true})
		return
	}
	if r.Method != http.MethodPost {
		writeAPIError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}
	var body struct {
		Username string `json:"username"`
		Password string `json:"password"`
	}
	_ = json.NewDecoder(io.LimitReader(r.Body, 1<<20)).Decode(&body)
	tok, user, err := auth.Login(body.Username, body.Password)
	if err != nil {
		writeAPIError(w, http.StatusUnauthorized, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"ok":    true,
		"token": tok,
		"user":  user.Public(),
	})
}

func (s *Server) handleAuthRegister(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodOptions {
		writeJSON(w, http.StatusOK, map[string]any{"ok": true})
		return
	}
	if r.Method != http.MethodPost {
		writeAPIError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}
	var body struct {
		Username string `json:"username"`
		Password string `json:"password"`
	}
	_ = json.NewDecoder(io.LimitReader(r.Body, 1<<20)).Decode(&body)
	user, err := auth.Register(body.Username, body.Password)
	if err != nil {
		writeAPIError(w, http.StatusBadRequest, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true, "user": user.Public()})
}

func (s *Server) handleAuthLogout(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodOptions {
		writeJSON(w, http.StatusOK, map[string]any{"ok": true})
		return
	}
	if r.Method != http.MethodPost {
		writeAPIError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}
	auth.Logout(auth.BearerFromHeader(r.Header.Get("Authorization")))
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

func (s *Server) handleAuthMe(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodOptions {
		writeJSON(w, http.StatusOK, map[string]any{"ok": true})
		return
	}
	u := authUserFrom(r.Context())
	if u == nil {
		tok := auth.BearerFromHeader(r.Header.Get("Authorization"))
		var err error
		u, err = auth.LookupToken(tok)
		if err != nil {
			writeAPIError(w, http.StatusUnauthorized, err.Error())
			return
		}
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true, "user": u.Public()})
}

func (s *Server) handleAdminUsers(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodOptions {
		writeJSON(w, http.StatusOK, map[string]any{"ok": true})
		return
	}
	switch r.Method {
	case http.MethodGet:
		list := auth.ListUsers()
		out := make([]map[string]any, 0, len(list))
		for _, u := range list {
			out = append(out, u.Public())
		}
		writeJSON(w, http.StatusOK, map[string]any{
			"ok":            true,
			"users":         out,
			"remoteAuth":    auth.RemoteAuthEnabled(),
			"allowRegister": auth.AllowRegister(),
		})
	case http.MethodPost:
		var body struct {
			Username string `json:"username"`
			Password string `json:"password"`
			Role     string `json:"role"`
		}
		_ = json.NewDecoder(io.LimitReader(r.Body, 1<<20)).Decode(&body)
		u, err := auth.CreateUser(body.Username, body.Password, body.Role)
		if err != nil {
			writeAPIError(w, http.StatusBadRequest, err.Error())
			return
		}
		writeJSON(w, http.StatusOK, map[string]any{"ok": true, "user": u.Public()})
	default:
		writeAPIError(w, http.StatusMethodNotAllowed, "method not allowed")
	}
}

func (s *Server) handleAdminUserAction(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodOptions {
		writeJSON(w, http.StatusOK, map[string]any{"ok": true})
		return
	}
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
		if err := auth.DeleteUser(id); err != nil {
			writeAPIError(w, http.StatusBadRequest, err.Error())
			return
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
		_ = json.NewDecoder(io.LimitReader(r.Body, 1<<20)).Decode(&body)
		if err := auth.ResetPassword(id, body.Password); err != nil {
			writeAPIError(w, http.StatusBadRequest, err.Error())
			return
		}
		writeJSON(w, http.StatusOK, map[string]any{"ok": true})
	default:
		writeAPIError(w, http.StatusBadRequest, "unknown action")
	}
}

func (s *Server) handleAdminSettings(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodOptions {
		writeJSON(w, http.StatusOK, map[string]any{"ok": true})
		return
	}
	if r.Method != http.MethodPost {
		writeAPIError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}
	var body struct {
		RemoteAuth    *bool `json:"remoteAuth"`
		AllowRegister *bool `json:"allowRegister"`
	}
	_ = json.NewDecoder(io.LimitReader(r.Body, 1<<20)).Decode(&body)
	if body.RemoteAuth != nil {
		_ = auth.SetRemoteAuth(*body.RemoteAuth)
	}
	if body.AllowRegister != nil {
		_ = auth.SetAllowRegister(*body.AllowRegister)
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"ok":            true,
		"remoteAuth":    auth.RemoteAuthEnabled(),
		"allowRegister": auth.AllowRegister(),
	})
}
