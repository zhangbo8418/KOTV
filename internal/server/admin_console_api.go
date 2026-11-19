package server

import (
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/bobo/KOTV/internal/auth"
	"github.com/bobo/KOTV/internal/cacheclean"
	"github.com/bobo/KOTV/internal/database"
	"github.com/bobo/KOTV/internal/grouppolicy"
	"github.com/bobo/KOTV/internal/hostmetrics"
	"github.com/bobo/KOTV/internal/paths"
	"github.com/bobo/KOTV/internal/remote"
	"github.com/bobo/KOTV/internal/settings"
	"github.com/bobo/KOTV/internal/usage"
)

func adminID() string {
	var b [8]byte
	_, _ = rand.Read(b[:])
	return hex.EncodeToString(b[:])
}

func (s *Server) adminDB() *database.DB {
	if api, ok := s.contentAPI.(interface{ GetDB() *database.DB }); ok {
		return api.GetDB()
	}
	// App embeds DB via content — fallback Open
	db, _ := database.Open()
	return db
}

func (s *Server) audit(r *http.Request, action, target, detail string) {
	actor := "local"
	if u := authUserFrom(r.Context()); u != nil {
		actor = u.Username
	}
	if db := s.adminDB(); db != nil {
		_ = db.InsertAdminAudit(adminID(), actor, action, target, detail)
	}
}

func (s *Server) handleAdminGroups(w http.ResponseWriter, r *http.Request) {
	db := s.adminDB()
	if db == nil {
		writeAPIError(w, http.StatusInternalServerError, "db unavailable")
		return
	}
	switch r.Method {
	case http.MethodGet:
		list, err := db.ListAuthGroups()
		if err != nil {
			writeAPIError(w, http.StatusInternalServerError, err.Error())
			return
		}
		out := make([]map[string]any, 0, len(list))
		for _, g := range list {
			vods, _ := db.ListGroupVodIDs(g.ID)
			lives, _ := db.ListGroupLives(g.ID)
			gs, _ := db.ListGroupSettings(g.ID)
			hides, _ := db.ListGroupSiteHides(g.ID)
			out = append(out, map[string]any{
				"id": g.ID, "name": g.Name, "note": g.Note, "enabled": g.Enabled, "sort": g.Sort,
				"vodIds": vods, "lives": livesToMaps(lives), "settings": gs, "siteHides": hides,
			})
		}
		writeJSON(w, http.StatusOK, map[string]any{"ok": true, "groups": out})
	case http.MethodPost:
		var body struct {
			ID      string `json:"id"`
			Name    string `json:"name"`
			Note    string `json:"note"`
			Enabled *bool  `json:"enabled"`
			Sort    int    `json:"sort"`
			CopyOf  string `json:"copyOf"`
		}
		_ = json.NewDecoder(io.LimitReader(r.Body, 1<<20)).Decode(&body)
		name := strings.TrimSpace(body.Name)
		if name == "" {
			writeAPIError(w, http.StatusBadRequest, "名称必填")
			return
		}
		id := strings.TrimSpace(body.ID)
		if id == "" {
			id = "g-" + adminID()
		}
		en := true
		if body.Enabled != nil {
			en = *body.Enabled
		}
		g := database.AuthGroup{ID: id, Name: name, Note: body.Note, Enabled: en, Sort: body.Sort, CreatedAt: time.Now().UTC()}
		if err := db.UpsertAuthGroup(g); err != nil {
			writeAPIError(w, http.StatusBadRequest, err.Error())
			return
		}
		if src := strings.TrimSpace(body.CopyOf); src != "" {
			if vods, err := db.ListGroupVodIDs(src); err == nil {
				_ = db.SetGroupVods(id, vods)
			}
			if lives, err := db.ListGroupLives(src); err == nil {
				for i := range lives {
					lives[i].ID = ""
					lives[i].GroupID = id
				}
				_ = db.ReplaceGroupLives(id, lives)
			}
			if gs, err := db.ListGroupSettings(src); err == nil {
				_ = db.SetGroupSettings(id, gs)
			}
			if hides, err := db.ListGroupSiteHides(src); err == nil {
				_ = db.SetGroupSiteHides(id, hides)
			}
		}
		s.audit(r, "group.upsert", id, name)
		writeJSON(w, http.StatusOK, map[string]any{"ok": true, "id": id})
	default:
		writeAPIError(w, http.StatusMethodNotAllowed, "method not allowed")
	}
}

func livesToMaps(lives []database.GroupLive) []map[string]any {
	out := make([]map[string]any, 0, len(lives))
	for _, l := range lives {
		out = append(out, map[string]any{
			"id": l.ID, "name": l.Name, "url": l.URL, "sort": l.Sort, "enabled": l.Enabled,
		})
	}
	return out
}

func (s *Server) handleAdminGroupAction(w http.ResponseWriter, r *http.Request) {
	db := s.adminDB()
	if db == nil {
		writeAPIError(w, http.StatusInternalServerError, "db unavailable")
		return
	}
	path := strings.TrimPrefix(r.URL.Path, "/api/v1/admin/groups/")
	parts := strings.Split(strings.Trim(path, "/"), "/")
	if len(parts) == 0 || parts[0] == "" {
		writeAPIError(w, http.StatusBadRequest, "missing group id")
		return
	}
	id := parts[0]
	action := ""
	if len(parts) > 1 {
		action = parts[1]
	}
	switch {
	case r.Method == http.MethodDelete && action == "":
		if err := db.DeleteAuthGroup(id); err != nil {
			writeAPIError(w, http.StatusBadRequest, err.Error())
			return
		}
		s.audit(r, "group.delete", id, "")
		writeJSON(w, http.StatusOK, map[string]any{"ok": true})
	case r.Method == http.MethodPut && action == "vods":
		var body struct {
			ConfigIDs []int64 `json:"configIds"`
		}
		_ = json.NewDecoder(io.LimitReader(r.Body, 1<<20)).Decode(&body)
		if err := db.SetGroupVods(id, body.ConfigIDs); err != nil {
			writeAPIError(w, http.StatusBadRequest, err.Error())
			return
		}
		s.audit(r, "group.vods", id, fmt.Sprintf("%d", len(body.ConfigIDs)))
		writeJSON(w, http.StatusOK, map[string]any{"ok": true})
	case (r.Method == http.MethodPut || r.Method == http.MethodGet) && action == "lives":
		if r.Method == http.MethodGet {
			lives, err := db.ListGroupLives(id)
			if err != nil {
				writeAPIError(w, http.StatusInternalServerError, err.Error())
				return
			}
			writeJSON(w, http.StatusOK, map[string]any{"ok": true, "lives": livesToMaps(lives)})
			return
		}
		var body struct {
			Lives []struct {
				ID      string `json:"id"`
				Name    string `json:"name"`
				URL     string `json:"url"`
				Sort    int    `json:"sort"`
				Enabled *bool  `json:"enabled"`
			} `json:"lives"`
		}
		_ = json.NewDecoder(io.LimitReader(r.Body, 1<<20)).Decode(&body)
		lives := make([]database.GroupLive, 0, len(body.Lives))
		for _, x := range body.Lives {
			en := true
			if x.Enabled != nil {
				en = *x.Enabled
			}
			lives = append(lives, database.GroupLive{ID: x.ID, GroupID: id, Name: x.Name, URL: x.URL, Sort: x.Sort, Enabled: en})
		}
		if err := db.ReplaceGroupLives(id, lives); err != nil {
			writeAPIError(w, http.StatusBadRequest, err.Error())
			return
		}
		s.audit(r, "group.lives", id, fmt.Sprintf("%d", len(lives)))
		writeJSON(w, http.StatusOK, map[string]any{"ok": true})
	case r.Method == http.MethodPut && action == "settings":
		var body map[string]string
		_ = json.NewDecoder(io.LimitReader(r.Body, 1<<20)).Decode(&body)
		if err := db.SetGroupSettings(id, body); err != nil {
			writeAPIError(w, http.StatusBadRequest, err.Error())
			return
		}
		s.audit(r, "group.settings", id, "")
		writeJSON(w, http.StatusOK, map[string]any{"ok": true})
	case r.Method == http.MethodPut && action == "siteHides":
		var body struct {
			Keys []string `json:"keys"`
		}
		_ = json.NewDecoder(io.LimitReader(r.Body, 1<<20)).Decode(&body)
		if err := db.SetGroupSiteHides(id, body.Keys); err != nil {
			writeAPIError(w, http.StatusBadRequest, err.Error())
			return
		}
		writeJSON(w, http.StatusOK, map[string]any{"ok": true})
	case r.Method == http.MethodGet && action == "export":
		vods, _ := db.ListGroupVodIDs(id)
		lives, _ := db.ListGroupLives(id)
		gs, _ := db.ListGroupSettings(id)
		hides, _ := db.ListGroupSiteHides(id)
		g, _ := db.GetAuthGroup(id)
		writeJSON(w, http.StatusOK, map[string]any{
			"ok": true,
			"group": map[string]any{
				"id": id, "name": func() string {
					if g != nil {
						return g.Name
					}
					return id
				}(),
				"vodIds": vods, "lives": livesToMaps(lives), "settings": gs, "siteHides": hides,
			},
		})
	case r.Method == http.MethodPost && action == "import":
		var body struct {
			VodIds    []int64           `json:"vodIds"`
			Lives     []database.GroupLive `json:"lives"`
			Settings  map[string]string `json:"settings"`
			SiteHides []string          `json:"siteHides"`
		}
		_ = json.NewDecoder(io.LimitReader(r.Body, 4<<20)).Decode(&body)
		_ = db.SetGroupVods(id, body.VodIds)
		for i := range body.Lives {
			body.Lives[i].GroupID = id
		}
		_ = db.ReplaceGroupLives(id, body.Lives)
		_ = db.SetGroupSettings(id, body.Settings)
		_ = db.SetGroupSiteHides(id, body.SiteHides)
		s.audit(r, "group.import", id, "")
		writeJSON(w, http.StatusOK, map[string]any{"ok": true})
	default:
		writeAPIError(w, http.StatusBadRequest, "unknown action")
	}
}

func (s *Server) handleAdminNotices(w http.ResponseWriter, r *http.Request) {
	db := s.adminDB()
	if db == nil {
		writeAPIError(w, http.StatusInternalServerError, "db unavailable")
		return
	}
	switch r.Method {
	case http.MethodGet:
		list, err := db.ListAdminNotices()
		if err != nil {
			writeAPIError(w, http.StatusInternalServerError, err.Error())
			return
		}
		out := make([]map[string]any, 0, len(list))
		for _, n := range list {
			acks, _ := db.CountNoticeAcks(n.ID)
			out = append(out, map[string]any{
				"id": n.ID, "scope": n.Scope, "targetId": n.TargetID, "kind": n.Kind,
				"title": n.Title, "body": n.Body, "link": n.Link, "sticky": n.Sticky,
				"priority": n.Priority, "startsAt": n.StartsAt, "endsAt": n.EndsAt,
				"createdAt": n.CreatedAt, "createdBy": n.CreatedBy, "ackCount": acks,
			})
		}
		writeJSON(w, http.StatusOK, map[string]any{"ok": true, "notices": out})
	case http.MethodPost:
		var body database.AdminNotice
		_ = json.NewDecoder(io.LimitReader(r.Body, 1<<20)).Decode(&body)
		isNew := strings.TrimSpace(body.ID) == ""
		if isNew {
			body.ID = "n-" + adminID()
		}
		if body.Kind == "" {
			body.Kind = "banner"
		}
		if body.Scope == "" {
			body.Scope = "all"
		}
		if u := authUserFrom(r.Context()); u != nil {
			body.CreatedBy = u.Username
		}
		if body.CreatedBy == "" {
			body.CreatedBy = "local"
		}
		if err := db.UpsertAdminNotice(body); err != nil {
			writeAPIError(w, http.StatusBadRequest, err.Error())
			return
		}
		action := "notice.update"
		if isNew {
			action = "notice.create"
		}
		s.audit(r, action, body.ID, body.Title)
		writeJSON(w, http.StatusOK, map[string]any{"ok": true, "id": body.ID})
	case http.MethodDelete:
		id := strings.TrimSpace(r.URL.Query().Get("id"))
		if id == "" {
			writeAPIError(w, http.StatusBadRequest, "missing id")
			return
		}
		_ = db.DeleteAdminNotice(id)
		s.audit(r, "notice.delete", id, "")
		writeJSON(w, http.StatusOK, map[string]any{"ok": true})
	default:
		writeAPIError(w, http.StatusMethodNotAllowed, "method not allowed")
	}
}

func (s *Server) handleAdminPushOpen(w http.ResponseWriter, r *http.Request) {
	if rejectUnlessPost(w, r) {
		return
	}
	var body struct {
		GroupID  string `json:"groupId"`
		UserID   string `json:"userId"`
		Kind     string `json:"kind"`
		Site     string `json:"site"`
		ID       string `json:"id"`
		Name     string `json:"name"`
		URL      string `json:"url"`
		Emergency bool  `json:"emergency"`
	}
	_ = json.NewDecoder(io.LimitReader(r.Body, 1<<20)).Decode(&body)
	if body.Kind == "" {
		body.Kind = "play"
	}
	cmd := remote.OpenCmd{Kind: body.Kind, Site: body.Site, ID: body.ID, Name: body.Name, URL: body.URL}
	targets := []string{}
	targetLabel := "broadcast"
	if body.UserID != "" {
		targets = append(targets, "u:"+body.UserID)
		targetLabel = "u:" + body.UserID
	} else if body.GroupID != "" {
		targetLabel = "g:" + body.GroupID
		for _, u := range auth.ListUsers() {
			if u.GroupID == body.GroupID && u.Enabled {
				pol := grouppolicy.Resolve(&u)
				if !body.Emergency && !pol.Caps["allowRemoteControl"] {
					continue
				}
				targets = append(targets, "u:"+u.ID)
			}
		}
	} else {
		remote.DefaultQueue.PushOpen(cmd, "")
	}
	for _, t := range targets {
		remote.DefaultQueue.PushOpen(cmd, t)
	}
	db := s.adminDB()
	payload, _ := json.Marshal(body)
	actor := "local"
	if u := authUserFrom(r.Context()); u != nil {
		actor = u.Username
	}
	if db != nil {
		_ = db.InsertPushLog(adminID(), actor, targetLabel, body.Kind, string(payload))
	}
	s.audit(r, "push.open", targetLabel, body.Kind)
	n := len(targets)
	if body.UserID == "" && body.GroupID == "" {
		n = -1 // broadcast
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true, "targets": n, "target": targetLabel})
}

func (s *Server) handleAdminPushLogs(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodGet {
		writeAPIError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}
	db := s.adminDB()
	if db == nil {
		writeAPIError(w, http.StatusInternalServerError, "db unavailable")
		return
	}
	limit := 50
	if v := r.URL.Query().Get("limit"); v != "" {
		if n, err := strconv.Atoi(v); err == nil && n > 0 {
			limit = n
		}
	}
	list, err := db.ListPushLog(limit)
	if err != nil {
		writeAPIError(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true, "logs": list})
}

func (s *Server) handleAdminStats(w http.ResponseWriter, r *http.Request) {
	db := s.adminDB()
	if db == nil {
		writeAPIError(w, http.StatusInternalServerError, "db unavailable")
		return
	}
	now := time.Now()
	from := now.Add(-24 * time.Hour).UnixMilli()
	to := now.UnixMilli()
	if v := r.URL.Query().Get("from"); v != "" {
		if n, err := strconv.ParseInt(v, 10, 64); err == nil {
			from = n
		}
	}
	if v := r.URL.Query().Get("to"); v != "" {
		if n, err := strconv.ParseInt(v, 10, 64); err == nil {
			to = n
		}
	}
	groupID := r.URL.Query().Get("groupId")
	platform := r.URL.Query().Get("platform")
	kind := strings.Trim(strings.TrimPrefix(r.URL.Path, "/api/v1/admin/stats"), "/")
	if kind == "" || kind == "summary" {
		sum, err := db.StatsSummary(from, to, groupID, platform)
		if err != nil {
			writeAPIError(w, http.StatusInternalServerError, err.Error())
			return
		}
		plats, _ := db.StatsPlatforms(from, to, groupID)
		audit, _ := db.ListAdminAudit(20)
		writeJSON(w, http.StatusOK, map[string]any{
			"ok": true, "summary": sum, "platforms": plats, "audit": audit,
			"from": from, "to": to,
		})
		return
	}
	switch kind {
	case "repos":
		rows, err := db.StatsTopRefs(from, to, "config_load", groupID, 30)
		if err != nil {
			writeAPIError(w, http.StatusInternalServerError, err.Error())
			return
		}
		enrichConfigRefNames(db, rows, int64(database.ConfigTypeSite))
		writeJSON(w, http.StatusOK, map[string]any{"ok": true, "rows": rows})
	case "lives":
		rows, err := db.StatsTopRefs(from, to, "live_load", groupID, 30)
		if err != nil {
			writeAPIError(w, http.StatusInternalServerError, err.Error())
			return
		}
		enrichConfigRefNames(db, rows, int64(database.ConfigTypeLive))
		writeJSON(w, http.StatusOK, map[string]any{"ok": true, "rows": rows})
	case "plays":
		rows, err := db.StatsTopRefs(from, to, "play", groupID, 30)
		if err != nil {
			writeAPIError(w, http.StatusInternalServerError, err.Error())
			return
		}
		writeJSON(w, http.StatusOK, map[string]any{"ok": true, "rows": rows})
	case "platforms":
		rows, err := db.StatsPlatforms(from, to, groupID)
		if err != nil {
			writeAPIError(w, http.StatusInternalServerError, err.Error())
			return
		}
		writeJSON(w, http.StatusOK, map[string]any{"ok": true, "rows": rows})
	case "online":
		sum, _ := db.StatsSummary(now.Add(-5*time.Minute).UnixMilli(), to, groupID, platform)
		var sessions []map[string]any
		if api, ok := s.contentAPI.(interface{ AdminOnlineSessions() []map[string]any }); ok {
			sessions = api.AdminOnlineSessions()
		}
		writeJSON(w, http.StatusOK, map[string]any{
			"ok": true, "onlineApprox": sum["dau"], "windowMin": 5, "sessions": sessions,
		})
	case "system", "host":
		snap := hostmetrics.Collect(paths.Root())
		var sessions []map[string]any
		if api, ok := s.contentAPI.(interface{ AdminOnlineSessions() []map[string]any }); ok {
			sessions = api.AdminOnlineSessions()
		}
		onlineApprox := 0
		if sum, err := db.StatsSummary(now.Add(-5*time.Minute).UnixMilli(), to, groupID, platform); err == nil {
			if n, ok := sum["dau"].(int); ok {
				onlineApprox = n
			}
		}
		writeJSON(w, http.StatusOK, map[string]any{
			"ok": true, "system": snap, "onlineApprox": onlineApprox,
			"sessionCount": len(sessions), "sessions": sessions,
		})
	case "searches":
		rows, err := db.StatsTopRefs(from, to, "search", groupID, 30)
		if err != nil {
			writeAPIError(w, http.StatusInternalServerError, err.Error())
			return
		}
		writeJSON(w, http.StatusOK, map[string]any{"ok": true, "rows": rows})
	case "denies":
		rows, err := db.StatsTopRefs(from, to, "policy_deny", groupID, 30)
		if err != nil {
			writeAPIError(w, http.StatusInternalServerError, err.Error())
			return
		}
		writeJSON(w, http.StatusOK, map[string]any{"ok": true, "rows": rows})
	case "errors":
		rows, err := db.StatsFailedRefs(from, to, groupID, 30)
		if err != nil {
			writeAPIError(w, http.StatusInternalServerError, err.Error())
			return
		}
		writeJSON(w, http.StatusOK, map[string]any{"ok": true, "rows": rows})
	default:
		writeAPIError(w, http.StatusBadRequest, "unknown stats kind")
	}
}

func (s *Server) handleAdminInvites(w http.ResponseWriter, r *http.Request) {
	db := s.adminDB()
	if db == nil {
		writeAPIError(w, http.StatusInternalServerError, "db unavailable")
		return
	}
	switch r.Method {
	case http.MethodGet:
		list, err := db.ListInvites()
		if err != nil {
			writeAPIError(w, http.StatusInternalServerError, err.Error())
			return
		}
		writeJSON(w, http.StatusOK, map[string]any{"ok": true, "invites": list})
	case http.MethodPost:
		var body struct {
			Code      string `json:"code"`
			GroupID   string `json:"groupId"`
			MaxUses   int    `json:"maxUses"`
			ExpiresAt int64  `json:"expiresAt"`
		}
		_ = json.NewDecoder(io.LimitReader(r.Body, 1<<20)).Decode(&body)
		if body.Code == "" {
			body.Code = strings.ToUpper(adminID()[:8])
		}
		if body.GroupID == "" {
			body.GroupID = database.DefaultGroupID
		}
		if err := db.UpsertInvite(body.Code, body.GroupID, body.MaxUses, body.ExpiresAt); err != nil {
			writeAPIError(w, http.StatusBadRequest, err.Error())
			return
		}
		s.audit(r, "invite.upsert", body.Code, body.GroupID)
		writeJSON(w, http.StatusOK, map[string]any{"ok": true, "code": body.Code})
	case http.MethodDelete:
		code := r.URL.Query().Get("code")
		_ = db.DeleteInvite(code)
		writeJSON(w, http.StatusOK, map[string]any{"ok": true})
	default:
		writeAPIError(w, http.StatusMethodNotAllowed, "method not allowed")
	}
}

func (s *Server) handleAdminAudit(w http.ResponseWriter, r *http.Request) {
	db := s.adminDB()
	if db == nil {
		writeAPIError(w, http.StatusInternalServerError, "db unavailable")
		return
	}
	list, err := db.ListAdminAudit(100)
	if err != nil {
		writeAPIError(w, http.StatusInternalServerError, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true, "audit": list})
}

func (s *Server) handleAdminConsoleSettings(w http.ResponseWriter, r *http.Request) {
	switch r.Method {
	case http.MethodGet:
		writeJSON(w, http.StatusOK, map[string]any{
			"ok":                 true,
			"remoteAuth":         auth.RemoteAuthEnabled(),
			"allowRegister":      auth.AllowRegister(),
			"updateUrl":          settings.Get(settings.UpdateURL),
			"defaultGroupId":     settings.Get("defaultGroupId"),
			"minClientVersion":   settings.Get("minClientVersion"),
			"maintenance":        settings.Get("maintenance"),
			"maintenanceMsg":     settings.Get("maintenanceMsg"),
			"usageRetentionDays": settings.Get("usageRetentionDays"),
			"usageSearchTerms":   settings.Get("usageSearchTerms"),
			"forceUpdate":        settings.Get("forceUpdate"),
			"requireInvite":      settings.Get(settings.RequireInvite),
			"requireApproval":    settings.Get(settings.RequireApproval),
			"maxDevices":         settings.Get("maxDevices"),
			"maxSessions":        settings.Get("maxSessions"),
			"ipAllow":            settings.Get("ipAllow"),
			"ipDeny":             settings.Get("ipDeny"),
			"accessHours":        settings.Get("accessHours"),
			"logo":               settings.Get("logo"),
			"wallpaper":          settings.Get("wallpaper"),
			"banner":             settings.Get("banner"),
			"aboutUrl":           settings.Get("aboutUrl"),
			"supportUrl":         settings.Get("supportUrl"),
			"footer":             settings.Get("footer"),
			"welcome":            settings.Get("welcome"),
		})
	case http.MethodPost:
		var body map[string]any
		_ = json.NewDecoder(io.LimitReader(r.Body, 1<<20)).Decode(&body)
		if v, ok := body["remoteAuth"].(bool); ok {
			_ = auth.SetRemoteAuth(v)
		}
		if v, ok := body["allowRegister"].(bool); ok {
			_ = auth.SetAllowRegister(v)
			if v && !auth.RequireApproval() {
				if _, has := body["requireApproval"]; !has {
					_ = auth.SetRequireApproval(true)
				}
			}
		}
		setStr := func(key string) {
			if v, ok := body[key].(string); ok {
				settings.Set(settings.Type(key), v)
			}
		}
		if v, ok := body["updateUrl"].(string); ok {
			settings.Set(settings.UpdateURL, v)
		}
		for _, k := range []string{
			"defaultGroupId", "minClientVersion", "maintenanceMsg", "usageRetentionDays",
			"usageSearchTerms", "requireInvite", "requireApproval", "maxDevices", "maxSessions",
			"ipAllow", "ipDeny", "accessHours",
			"logo", "wallpaper", "banner", "aboutUrl", "supportUrl", "footer", "welcome",
		} {
			setStr(k)
		}
		setBool := func(key string) {
			if v, ok := body[key].(bool); ok {
				if v {
					settings.Set(settings.Type(key), "true")
				} else {
					settings.Set(settings.Type(key), "false")
				}
			}
		}
		setBool("maintenance")
		setBool("forceUpdate")
		setBool("requireInvite")
		setBool("requireApproval")
		_ = settings.Save()
		s.audit(r, "settings.save", "", "")
		writeJSON(w, http.StatusOK, map[string]any{"ok": true})
	default:
		writeAPIError(w, http.StatusMethodNotAllowed, "method not allowed")
	}
}

func (s *Server) handleAdminSessions(w http.ResponseWriter, r *http.Request) {
	type onlineAPI interface {
		AdminOnlineSessions() []map[string]any
	}
	switch r.Method {
	case http.MethodGet:
		var rows []map[string]any
		if api, ok := s.contentAPI.(onlineAPI); ok {
			rows = api.AdminOnlineSessions()
		}
		writeJSON(w, http.StatusOK, map[string]any{"ok": true, "sessions": rows})
	case http.MethodPost:
		var body struct {
			Action string `json:"action"`
			UserID string `json:"userId"`
		}
		_ = json.NewDecoder(io.LimitReader(r.Body, 1<<20)).Decode(&body)
		if body.Action == "kick" && body.UserID != "" {
			_ = auth.ForceLogout(body.UserID)
			if api := s.content(); api != nil {
				_ = api.APISessionLeave() // no-op if not that user; release via presence
			}
			if leaver, ok := s.contentAPI.(interface{ AdminKickUser(string) }); ok {
				leaver.AdminKickUser(body.UserID)
			} else {
				// fallback: ForceLogout already done
			}
			s.audit(r, "session.kick", body.UserID, "")
			writeJSON(w, http.StatusOK, map[string]any{"ok": true})
			return
		}
		writeAPIError(w, http.StatusBadRequest, "unknown action")
	default:
		writeAPIError(w, http.StatusMethodNotAllowed, "method not allowed")
	}
}

// handleAdminLogs 引擎日志目录：列表 / 读尾 / 清理（与缓存清理「仅日志」同源）。
func (s *Server) handleAdminLogs(w http.ResponseWriter, r *http.Request) {
	switch r.Method {
	case http.MethodGet:
		name := strings.TrimSpace(r.URL.Query().Get("name"))
		if name == "" {
			list, err := cacheclean.ListLogs()
			if err != nil {
				writeAPIError(w, http.StatusInternalServerError, err.Error())
				return
			}
			writeJSON(w, http.StatusOK, map[string]any{
				"ok":  true,
				"dir": paths.LogDir(),
				"files": list,
			})
			return
		}
		maxBytes, _ := strconv.ParseInt(strings.TrimSpace(r.URL.Query().Get("tail")), 10, 64)
		text, size, err := cacheclean.ReadLogTail(name, maxBytes)
		if err != nil {
			writeAPIError(w, http.StatusBadRequest, err.Error())
			return
		}
		writeJSON(w, http.StatusOK, map[string]any{
			"ok":      true,
			"name":    name,
			"size":    size,
			"content": text,
		})
	case http.MethodPost:
		var body struct {
			Action string `json:"action"`
			Name   string `json:"name"`
		}
		_ = json.NewDecoder(io.LimitReader(r.Body, 1<<20)).Decode(&body)
		action := strings.TrimSpace(strings.ToLower(body.Action))
		if action == "" {
			action = "clear"
		}
		switch action {
		case "clear":
			name := strings.TrimSpace(body.Name)
			var freed int64
			var err error
			if name == "" {
				freed, err = cacheclean.ClearLogs()
			} else {
				freed, err = cacheclean.ClearLogFile(name)
			}
			if err != nil {
				writeAPIError(w, http.StatusBadRequest, err.Error())
				return
			}
			ref := name
			if ref == "" {
				ref = "*"
			}
			s.audit(r, "ops.logs-clear", ref, "")
			writeJSON(w, http.StatusOK, map[string]any{"ok": true, "freedBytes": freed})
		default:
			writeAPIError(w, http.StatusBadRequest, "unknown action")
		}
	default:
		writeAPIError(w, http.StatusMethodNotAllowed, "method not allowed")
	}
}

func (s *Server) handleAdminOps(w http.ResponseWriter, r *http.Request) {
	if rejectUnlessPost(w, r) {
		return
	}
	path := strings.Trim(strings.TrimPrefix(r.URL.Path, "/api/v1/admin/ops/"), "/")
	var body map[string]any
	_ = json.NewDecoder(io.LimitReader(r.Body, 1<<20)).Decode(&body)
	switch path {
	case "cache-purge":
		uid, _ := body["userId"].(string)
		if api, ok := s.contentAPI.(interface{ AdminPurgeUserCache(string) }); ok {
			api.AdminPurgeUserCache(uid)
		}
		s.audit(r, "ops.cache-purge", uid, "")
		writeJSON(w, http.StatusOK, map[string]any{"ok": true})
	case "probe-repo":
		url, _ := body["url"].(string)
		url = strings.TrimSpace(url)
		if url == "" {
			writeAPIError(w, http.StatusBadRequest, "missing url")
			return
		}
		client := &http.Client{Timeout: 8 * time.Second}
		resp, err := client.Get(url)
		ok := err == nil && resp != nil && resp.StatusCode < 500
		code := 0
		if resp != nil {
			code = resp.StatusCode
			_ = resp.Body.Close()
		}
		msg := ""
		if err != nil {
			msg = err.Error()
		}
		writeJSON(w, http.StatusOK, map[string]any{"ok": ok, "status": code, "error": msg})
	default:
		writeAPIError(w, http.StatusBadRequest, "unknown ops")
	}
}

func (s *Server) handleNoticeAck(w http.ResponseWriter, r *http.Request) {
	if rejectUnlessPost(w, r) {
		return
	}
	u := authUserFrom(r.Context())
	if u == nil {
		writeAPIError(w, http.StatusUnauthorized, "需要登录")
		return
	}
	var body struct {
		ID string `json:"id"`
	}
	_ = json.NewDecoder(io.LimitReader(r.Body, 1<<20)).Decode(&body)
	if body.ID == "" {
		writeAPIError(w, http.StatusBadRequest, "missing id")
		return
	}
	db := s.adminDB()
	if db == nil {
		writeAPIError(w, http.StatusInternalServerError, "db unavailable")
		return
	}
	_ = db.AckNotice(u.ID, body.ID)
	usage.Record(usage.FromRequest(r, u), "notice_ack", "notice", body.ID, "", true, "", 0)
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}
