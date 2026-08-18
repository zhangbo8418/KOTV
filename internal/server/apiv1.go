package server

import (
	"encoding/json"
	"io"
	"net"
	"net/http"
	"strconv"
	"strings"

	"github.com/bobo/KOTV/internal/hostclient"
	"github.com/bobo/KOTV/internal/playproxy"
	"github.com/bobo/KOTV/internal/remote"
)

// ContentAPI Flutter /api/v1 后端（由 app.App 实现，避免 server→app 循环依赖）。
type ContentAPI interface {
	APIHealth() map[string]any
	APIGetConfig() map[string]any
	APILoadConfig(source string) error
	APISetHome(siteKey string) error
	APIHome() (map[string]any, error)
	APICategory(tid, pg string, extend map[string]string) (map[string]any, error)
	APIAction(siteKey, action string) (map[string]any, error)
	APIDetail(siteKey, vodID string) (map[string]any, error)
	APIDetailExpand(siteKey, vodID string, flags []map[string]any) (map[string]any, error)
	APIBtProgress() map[string]any
	APISearch(keyword string, siteKeys []string) (map[string]any, error)
	APIPlay(siteKey, vodID, flag, episodeURL string, qualIdx int) (map[string]any, error)
	APIRemotePoll() map[string]any
	APISetMedia(state map[string]string)
	APIListRepos() map[string]any
	APIDeleteRepo(url string) error
	APIEditRepo(oldURL, newURL, name string) error
	APIDeleteLive(url string) error
	APIEditLive(oldURL, newURL, name string) error
	APIGetSettings() map[string]any
	APISetSettings(kv map[string]string) error
	APIToggleSite(key, field string, all *bool) error
	APILiveSources() map[string]any
	APILiveLoad(index int, url string) (map[string]any, error)
	APILivePlay(group, channel, line int) (map[string]any, error)
	APILiveUnlock(group int, password string) error
	APILiveEPG(group, channel int) (map[string]any, error)
	APILiveCatchup(group, channel, day, prog int) (map[string]any, error)
	APIPlayerStatus() map[string]any
	APIPlayerExternal(playURL, playerVal string) error
	APIPlayerEmbed(playURL, playerVal, histKey string) error
	APIPlayerControl(cmd string, value float64, mode string) error
	APITools(action string, params map[string]any) (map[string]any, error)
	APICancelPending(opts map[string]any) map[string]any
	APISessionPing() map[string]any
	APISessionLeave() map[string]any
}

func (s *Server) SetContentAPI(api ContentAPI) {
	s.mu.Lock()
	s.contentAPI = api
	s.mu.Unlock()
}

// SetShutdownHook 注册本机优雅停机回调（仅 /api/v1/shutdown 触发）。
func (s *Server) SetShutdownHook(fn func()) {
	s.mu.Lock()
	s.onShutdown = fn
	s.mu.Unlock()
}

func (s *Server) requestShutdown() bool {
	s.mu.RLock()
	fn := s.onShutdown
	s.mu.RUnlock()
	if fn == nil {
		return false
	}
	fn()
	return true
}

func (s *Server) content() ContentAPI {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.contentAPI
}

func (s *Server) registerAPIv1(mux *http.ServeMux) {
	wrap := s.withAuth
	mux.HandleFunc("/api/v1/health", wrap(s.handleAPIv1Health))
	mux.HandleFunc("/api/v1/net", wrap(s.handleAPIv1Net))
	mux.HandleFunc("/api/v1/auth/status", wrap(s.handleAuthStatus))
	mux.HandleFunc("/api/v1/auth/login", wrap(s.handleAuthLogin))
	mux.HandleFunc("/api/v1/auth/register", wrap(s.handleAuthRegister))
	mux.HandleFunc("/api/v1/auth/logout", wrap(s.handleAuthLogout))
	mux.HandleFunc("/api/v1/auth/me", wrap(s.handleAuthMe))
	mux.HandleFunc("/api/v1/auth/password", wrap(s.handleAuthPassword))
	mux.HandleFunc("/api/v1/admin/users", s.requireAdmin(s.handleAdminUsers))
	mux.HandleFunc("/api/v1/admin/users/", s.requireAdmin(s.handleAdminUserAction))
	mux.HandleFunc("/api/v1/admin/settings", s.requireAdmin(s.handleAdminSettings))
	mux.HandleFunc("/api/v1/session/ping", wrap(s.handleSessionPing))
	mux.HandleFunc("/api/v1/session/leave", wrap(s.handleSessionLeave))
	mux.HandleFunc("/api/v1/config", wrap(s.handleAPIv1Config))
	mux.HandleFunc("/api/v1/home", wrap(s.handleAPIv1Home))
	mux.HandleFunc("/api/v1/category", wrap(s.handleAPIv1Category))
	mux.HandleFunc("/api/v1/action", wrap(s.handleAPIv1Action))
	mux.HandleFunc("/api/v1/detail", wrap(s.handleAPIv1Detail))
	mux.HandleFunc("/api/v1/detail/expand", wrap(s.handleAPIv1DetailExpand))
	mux.HandleFunc("/api/v1/bt/progress", wrap(s.handleAPIv1BtProgress))
	mux.HandleFunc("/api/v1/search", wrap(s.handleAPIv1Search))
	mux.HandleFunc("/api/v1/play", wrap(s.handleAPIv1Play))
	mux.HandleFunc("/api/v1/sites", wrap(s.handleAPIv1Sites))
	mux.HandleFunc("/api/v1/remote/poll", wrap(s.handleAPIv1RemotePoll))
	mux.HandleFunc("/api/v1/media", wrap(s.handleAPIv1Media))
	mux.HandleFunc("/api/v1/repos", wrap(s.handleAPIv1Repos))
	mux.HandleFunc("/api/v1/settings", wrap(s.handleAPIv1Settings))
	mux.HandleFunc("/api/v1/live", wrap(s.handleAPIv1Live))
	mux.HandleFunc("/api/v1/player", wrap(s.handleAPIv1Player))
	mux.HandleFunc("/api/v1/tools", wrap(s.handleAPIv1Tools))
	mux.HandleFunc("/api/v1/ui/poll", wrap(s.handleAPIv1UIPoll))
	mux.HandleFunc("/api/v1/ui/reply", wrap(s.handleAPIv1UIReply))
	mux.HandleFunc("/api/v1/cancel", wrap(s.handleAPIv1Cancel))
	mux.HandleFunc("/api/v1/shutdown", wrap(s.handleAPIv1Shutdown))
}

// withHostClient 把请求头里的 X-Kotv-Client-Id 绑到当前 goroutine，供 JAR 调用携带。
func (s *Server) withHostClient(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		done := hostclient.Enter(clientIDFromRequest(r))
		defer done()
		next(w, r)
	}
}

func clientIDFromRequest(r *http.Request) string {
	if v := strings.TrimSpace(r.Header.Get("X-Kotv-Client-Id")); v != "" {
		return v
	}
	return strings.TrimSpace(r.URL.Query().Get("clientId"))
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.Header().Set("Access-Control-Allow-Origin", "*")
	w.Header().Set("Access-Control-Allow-Headers", "Content-Type, X-Kotv-Client-Id, X-Kotv-Client-Platform, Authorization")
	w.Header().Set("Access-Control-Allow-Methods", "GET, POST, DELETE, OPTIONS")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

func writeAPIError(w http.ResponseWriter, status int, msg string) {
	writeJSON(w, status, map[string]any{"ok": false, "error": msg})
}

func (s *Server) handleAPIv1Health(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodOptions {
		writeJSON(w, http.StatusOK, map[string]any{"ok": true})
		return
	}
	api := s.content()
	if api == nil {
		writeJSON(w, http.StatusOK, map[string]any{"ok": true, "engine": "kotv", "ready": false})
		return
	}
	writeJSON(w, http.StatusOK, api.APIHealth())
}

// handleAPIv1Net 缓冲浮层测速：代理累计下行字节（与播放器解耦，Traffic 思路）。
func (s *Server) handleAPIv1Net(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodOptions {
		writeJSON(w, http.StatusOK, map[string]any{"ok": true})
		return
	}
	if r.Method != http.MethodGet {
		writeAPIError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{
		"ok":      true,
		"rxBytes": playproxy.RxBytes(),
	})
}

func (s *Server) handleAPIv1Config(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodOptions {
		writeJSON(w, http.StatusOK, map[string]any{"ok": true})
		return
	}
	api := s.content()
	if api == nil {
		writeAPIError(w, http.StatusServiceUnavailable, "content api unavailable")
		return
	}
	switch r.Method {
	case http.MethodGet:
		writeJSON(w, http.StatusOK, api.APIGetConfig())
	case http.MethodPost:
		var body struct {
			Source string `json:"source"`
			URL    string `json:"url"`
		}
		raw, _ := io.ReadAll(io.LimitReader(r.Body, 8<<20))
		_ = json.Unmarshal(raw, &body)
		src := strings.TrimSpace(body.Source)
		if src == "" {
			src = strings.TrimSpace(body.URL)
		}
		if src == "" {
			src = strings.TrimSpace(string(raw))
			if strings.HasPrefix(src, "\"") {
				_ = json.Unmarshal(raw, &src)
			}
		}
		if src == "" {
			writeAPIError(w, http.StatusBadRequest, "missing source")
			return
		}
		if err := api.APILoadConfig(src); err != nil {
			writeAPIError(w, http.StatusBadRequest, err.Error())
			return
		}
		writeJSON(w, http.StatusOK, api.APIGetConfig())
	default:
		writeAPIError(w, http.StatusMethodNotAllowed, "method not allowed")
	}
}

func (s *Server) handleAPIv1Sites(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodOptions {
		writeJSON(w, http.StatusOK, map[string]any{"ok": true})
		return
	}
	api := s.content()
	if api == nil {
		writeAPIError(w, http.StatusServiceUnavailable, "content api unavailable")
		return
	}
	if r.Method == http.MethodPost {
		var body struct {
			Home   string `json:"home"`
			Toggle string `json:"toggle"`
			Key    string `json:"key"`
			All    *bool  `json:"all"`
		}
		_ = json.NewDecoder(r.Body).Decode(&body)
		if t := strings.TrimSpace(body.Toggle); t != "" {
			if err := api.APIToggleSite(body.Key, t, body.All); err != nil {
				writeAPIError(w, http.StatusBadRequest, err.Error())
				return
			}
		} else {
			if strings.TrimSpace(body.Home) == "" {
				writeAPIError(w, http.StatusBadRequest, "missing home")
				return
			}
			if err := api.APISetHome(body.Home); err != nil {
				writeAPIError(w, http.StatusBadRequest, err.Error())
				return
			}
		}
	}
	writeJSON(w, http.StatusOK, api.APIGetConfig())
}

func (s *Server) handleAPIv1Home(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodOptions {
		writeJSON(w, http.StatusOK, map[string]any{"ok": true})
		return
	}
	api := s.content()
	if api == nil {
		writeAPIError(w, http.StatusServiceUnavailable, "content api unavailable")
		return
	}
	out, err := api.APIHome()
	if err != nil {
		writeAPIError(w, http.StatusBadGateway, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, out)
}

func (s *Server) handleAPIv1Category(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodOptions {
		writeJSON(w, http.StatusOK, map[string]any{"ok": true})
		return
	}
	api := s.content()
	if api == nil {
		writeAPIError(w, http.StatusServiceUnavailable, "content api unavailable")
		return
	}
	q := r.URL.Query()
	tid := q.Get("tid")
	pg := q.Get("pg")
	if pg == "" {
		pg = "1"
	}
	extend := map[string]string{}
	for k, vs := range q {
		if k == "tid" || k == "pg" {
			continue
		}
		if len(vs) > 0 {
			extend[k] = vs[0]
		}
	}
	if r.Method == http.MethodPost {
		var body struct {
			Tid    string            `json:"tid"`
			Pg     string            `json:"pg"`
			Extend map[string]string `json:"extend"`
		}
		_ = json.NewDecoder(r.Body).Decode(&body)
		if body.Tid != "" {
			tid = body.Tid
		}
		if body.Pg != "" {
			pg = body.Pg
		}
		if body.Extend != nil {
			extend = body.Extend
		}
	}
	if tid == "" {
		writeAPIError(w, http.StatusBadRequest, "missing tid")
		return
	}
	out, err := api.APICategory(tid, pg, extend)
	if err != nil {
		writeAPIError(w, http.StatusBadGateway, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, out)
}

func (s *Server) handleAPIv1Action(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodOptions {
		writeJSON(w, http.StatusOK, map[string]any{"ok": true})
		return
	}
	if r.Method != http.MethodPost {
		writeAPIError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}
	api := s.content()
	if api == nil {
		writeAPIError(w, http.StatusServiceUnavailable, "content api unavailable")
		return
	}
	var body struct {
		Site   string `json:"site"`
		Action string `json:"action"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		writeAPIError(w, http.StatusBadRequest, "invalid json")
		return
	}
	action := strings.TrimSpace(body.Action)
	if action == "" {
		writeAPIError(w, http.StatusBadRequest, "missing action")
		return
	}
	out, err := api.APIAction(strings.TrimSpace(body.Site), action)
	if err != nil {
		writeAPIError(w, http.StatusBadGateway, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, out)
}

func (s *Server) handleAPIv1Detail(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodOptions {
		writeJSON(w, http.StatusOK, map[string]any{"ok": true})
		return
	}
	api := s.content()
	if api == nil {
		writeAPIError(w, http.StatusServiceUnavailable, "content api unavailable")
		return
	}
	siteKey := r.URL.Query().Get("site")
	vodID := r.URL.Query().Get("id")
	if r.Method == http.MethodPost {
		var body struct {
			Site string `json:"site"`
			ID   string `json:"id"`
		}
		_ = json.NewDecoder(r.Body).Decode(&body)
		if body.Site != "" {
			siteKey = body.Site
		}
		if body.ID != "" {
			vodID = body.ID
		}
	}
	if vodID == "" {
		writeAPIError(w, http.StatusBadRequest, "missing id")
		return
	}
	out, err := api.APIDetail(siteKey, vodID)
	if err != nil {
		writeAPIError(w, http.StatusBadGateway, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, out)
}

func (s *Server) handleAPIv1DetailExpand(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodOptions {
		writeJSON(w, http.StatusOK, map[string]any{"ok": true})
		return
	}
	api := s.content()
	if api == nil {
		writeAPIError(w, http.StatusServiceUnavailable, "content api unavailable")
		return
	}
	siteKey := r.URL.Query().Get("site")
	vodID := r.URL.Query().Get("id")
	var flags []map[string]any
	if r.Method == http.MethodPost {
		var body struct {
			Site  string           `json:"site"`
			ID    string           `json:"id"`
			Flags []map[string]any `json:"flags"`
		}
		_ = json.NewDecoder(r.Body).Decode(&body)
		if body.Site != "" {
			siteKey = body.Site
		}
		if body.ID != "" {
			vodID = body.ID
		}
		flags = body.Flags
	}
	if vodID == "" {
		writeAPIError(w, http.StatusBadRequest, "missing id")
		return
	}
	out, err := api.APIDetailExpand(siteKey, vodID, flags)
	if err != nil {
		writeAPIError(w, http.StatusBadGateway, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, out)
}

func (s *Server) handleAPIv1BtProgress(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodOptions {
		writeJSON(w, http.StatusOK, map[string]any{"ok": true})
		return
	}
	api := s.content()
	if api == nil {
		writeAPIError(w, http.StatusServiceUnavailable, "content api unavailable")
		return
	}
	writeJSON(w, http.StatusOK, api.APIBtProgress())
}

func (s *Server) handleAPIv1Search(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodOptions {
		writeJSON(w, http.StatusOK, map[string]any{"ok": true})
		return
	}
	api := s.content()
	if api == nil {
		writeAPIError(w, http.StatusServiceUnavailable, "content api unavailable")
		return
	}
	keyword := strings.TrimSpace(r.URL.Query().Get("wd"))
	var siteKeys []string
	if r.Method == http.MethodPost {
		var body struct {
			Keyword  string   `json:"keyword"`
			Wd       string   `json:"wd"`
			SiteKeys []string `json:"sites"`
		}
		_ = json.NewDecoder(r.Body).Decode(&body)
		if body.Keyword != "" {
			keyword = body.Keyword
		} else if body.Wd != "" {
			keyword = body.Wd
		}
		siteKeys = body.SiteKeys
	}
	if keyword == "" {
		writeAPIError(w, http.StatusBadRequest, "missing keyword")
		return
	}
	out, err := api.APISearch(keyword, siteKeys)
	if err != nil {
		writeAPIError(w, http.StatusBadGateway, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, out)
}

func (s *Server) handleAPIv1Play(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodOptions {
		writeJSON(w, http.StatusOK, map[string]any{"ok": true})
		return
	}
	if r.Method != http.MethodPost && r.Method != http.MethodGet {
		writeAPIError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}
	api := s.content()
	if api == nil {
		writeAPIError(w, http.StatusServiceUnavailable, "content api unavailable")
		return
	}
	siteKey := r.URL.Query().Get("site")
	vodID := r.URL.Query().Get("id")
	flag := r.URL.Query().Get("flag")
	ep := r.URL.Query().Get("url")
	qualIdx := 0
	if v := r.URL.Query().Get("qual"); v != "" {
		qualIdx, _ = strconv.Atoi(v)
	}
	if r.Method == http.MethodPost {
		var body struct {
			Site    string `json:"site"`
			ID      string `json:"id"`
			Flag    string `json:"flag"`
			URL     string `json:"url"`
			Episode string `json:"episode"`
			Qual    int    `json:"qual"`
		}
		_ = json.NewDecoder(r.Body).Decode(&body)
		if body.Site != "" {
			siteKey = body.Site
		}
		if body.ID != "" {
			vodID = body.ID
		}
		if body.Flag != "" {
			flag = body.Flag
		}
		if body.URL != "" {
			ep = body.URL
		} else if body.Episode != "" {
			ep = body.Episode
		}
		qualIdx = body.Qual
	}
	if ep == "" {
		writeAPIError(w, http.StatusBadRequest, "missing episode url")
		return
	}
	out, err := api.APIPlay(siteKey, vodID, flag, ep, qualIdx)
	if err != nil {
		writeAPIError(w, http.StatusBadGateway, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, out)
}

func (s *Server) handleAPIv1RemotePoll(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodOptions {
		writeJSON(w, http.StatusOK, map[string]any{"ok": true})
		return
	}
	api := s.content()
	if api == nil {
		writeJSON(w, http.StatusOK, map[string]any{"ok": true, "controls": []any{}, "searches": []any{}})
		return
	}
	writeJSON(w, http.StatusOK, api.APIRemotePoll())
}

func (s *Server) handleAPIv1Media(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodOptions {
		writeJSON(w, http.StatusOK, map[string]any{"ok": true})
		return
	}
	api := s.content()
	if api == nil {
		writeAPIError(w, http.StatusServiceUnavailable, "content api unavailable")
		return
	}
	if r.Method == http.MethodGet {
		writeJSON(w, http.StatusOK, map[string]any{"ok": true, "media": remote.SnapshotMediaFromStore()})
		return
	}
	if r.Method != http.MethodPost {
		writeAPIError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}
	var body map[string]string
	_ = json.NewDecoder(io.LimitReader(r.Body, 1<<20)).Decode(&body)
	api.APISetMedia(body)
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

func (s *Server) handleAPIv1Repos(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodOptions {
		writeJSON(w, http.StatusOK, map[string]any{"ok": true})
		return
	}
	api := s.content()
	if api == nil {
		writeAPIError(w, http.StatusServiceUnavailable, "content api unavailable")
		return
	}
	switch r.Method {
	case http.MethodGet:
		writeJSON(w, http.StatusOK, api.APIListRepos())
	case http.MethodPost:
		var body struct {
			Action string `json:"action"`
			URL    string `json:"url"`
			OldURL string `json:"oldUrl"`
			Name   string `json:"name"`
		}
		_ = json.NewDecoder(io.LimitReader(r.Body, 1<<20)).Decode(&body)
		oldURL := strings.TrimSpace(body.OldURL)
		if oldURL == "" {
			oldURL = strings.TrimSpace(body.URL)
		}
		newURL := strings.TrimSpace(body.URL)
		switch strings.ToLower(strings.TrimSpace(body.Action)) {
		case "edit", "rename":
			if err := api.APIEditRepo(oldURL, newURL, body.Name); err != nil {
				writeAPIError(w, http.StatusBadRequest, err.Error())
				return
			}
			writeJSON(w, http.StatusOK, map[string]any{"ok": true})
		default:
			writeAPIError(w, http.StatusBadRequest, "unknown action")
		}
	case http.MethodDelete:
		url := strings.TrimSpace(r.URL.Query().Get("url"))
		if r.Body != nil {
			var body struct {
				URL string `json:"url"`
			}
			_ = json.NewDecoder(io.LimitReader(r.Body, 1<<20)).Decode(&body)
			if body.URL != "" {
				url = body.URL
			}
		}
		if url == "" {
			writeAPIError(w, http.StatusBadRequest, "missing url")
			return
		}
		if err := api.APIDeleteRepo(url); err != nil {
			writeAPIError(w, http.StatusBadRequest, err.Error())
			return
		}
		writeJSON(w, http.StatusOK, map[string]any{"ok": true})
	default:
		writeAPIError(w, http.StatusMethodNotAllowed, "method not allowed")
	}
}

func (s *Server) handleAPIv1Settings(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodOptions {
		writeJSON(w, http.StatusOK, map[string]any{"ok": true})
		return
	}
	api := s.content()
	if api == nil {
		writeAPIError(w, http.StatusServiceUnavailable, "content api unavailable")
		return
	}
	switch r.Method {
	case http.MethodGet:
		writeJSON(w, http.StatusOK, api.APIGetSettings())
	case http.MethodPost:
		var body struct {
			Key      string            `json:"key"`
			Value    string            `json:"value"`
			Settings map[string]string `json:"settings"`
		}
		_ = json.NewDecoder(io.LimitReader(r.Body, 1<<20)).Decode(&body)
		kv := map[string]string{}
		for k, v := range body.Settings {
			kv[k] = v
		}
		if strings.TrimSpace(body.Key) != "" {
			kv[body.Key] = body.Value
		}
		if len(kv) == 0 {
			writeAPIError(w, http.StatusBadRequest, "missing settings")
			return
		}
		if err := api.APISetSettings(kv); err != nil {
			writeAPIError(w, http.StatusBadRequest, err.Error())
			return
		}
		writeJSON(w, http.StatusOK, api.APIGetSettings())
	default:
		writeAPIError(w, http.StatusMethodNotAllowed, "method not allowed")
	}
}

func (s *Server) handleAPIv1Live(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodOptions {
		writeJSON(w, http.StatusOK, map[string]any{"ok": true})
		return
	}
	api := s.content()
	if api == nil {
		writeAPIError(w, http.StatusServiceUnavailable, "content api unavailable")
		return
	}
	if r.Method == http.MethodGet {
		writeJSON(w, http.StatusOK, api.APILiveSources())
		return
	}
	if r.Method != http.MethodPost {
		writeAPIError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}
	var body struct {
		Action   string `json:"action"`
		Index    int    `json:"index"`
		URL      string `json:"url"`
		OldURL   string `json:"oldUrl"`
		Name     string `json:"name"`
		Group    int    `json:"group"`
		Channel  int    `json:"channel"`
		Line     int    `json:"line"`
		Password string `json:"password"`
		Day      int    `json:"day"`
		Prog     int    `json:"prog"`
	}
	_ = json.NewDecoder(io.LimitReader(r.Body, 1<<20)).Decode(&body)
	switch strings.ToLower(strings.TrimSpace(body.Action)) {
	case "", "sources":
		writeJSON(w, http.StatusOK, api.APILiveSources())
	case "load":
		out, err := api.APILiveLoad(body.Index, body.URL)
		if err != nil {
			writeAPIError(w, http.StatusBadGateway, err.Error())
			return
		}
		writeJSON(w, http.StatusOK, out)
	case "play":
		out, err := api.APILivePlay(body.Group, body.Channel, body.Line)
		if err != nil {
			writeAPIError(w, http.StatusBadGateway, err.Error())
			return
		}
		writeJSON(w, http.StatusOK, out)
	case "unlock":
		if err := api.APILiveUnlock(body.Group, body.Password); err != nil {
			writeAPIError(w, http.StatusForbidden, err.Error())
			return
		}
		writeJSON(w, http.StatusOK, map[string]any{"ok": true})
	case "epg":
		out, err := api.APILiveEPG(body.Group, body.Channel)
		if err != nil {
			writeAPIError(w, http.StatusBadGateway, err.Error())
			return
		}
		writeJSON(w, http.StatusOK, out)
	case "delete":
		if err := api.APIDeleteLive(body.URL); err != nil {
			writeAPIError(w, http.StatusBadRequest, err.Error())
			return
		}
		writeJSON(w, http.StatusOK, map[string]any{"ok": true})
	case "edit", "rename":
		oldURL := strings.TrimSpace(body.OldURL)
		if oldURL == "" {
			oldURL = strings.TrimSpace(body.URL)
		}
		if err := api.APIEditLive(oldURL, body.URL, body.Name); err != nil {
			writeAPIError(w, http.StatusBadRequest, err.Error())
			return
		}
		writeJSON(w, http.StatusOK, map[string]any{"ok": true})
	case "catchup":
		out, err := api.APILiveCatchup(body.Group, body.Channel, body.Day, body.Prog)
		if err != nil {
			writeAPIError(w, http.StatusBadGateway, err.Error())
			return
		}
		writeJSON(w, http.StatusOK, out)
	default:
		writeAPIError(w, http.StatusBadRequest, "unknown action")
	}
}

func (s *Server) handleAPIv1Player(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodOptions {
		writeJSON(w, http.StatusOK, map[string]any{"ok": true})
		return
	}
	api := s.content()
	if api == nil {
		writeAPIError(w, http.StatusServiceUnavailable, "content api unavailable")
		return
	}
	switch r.Method {
	case http.MethodGet:
		writeJSON(w, http.StatusOK, api.APIPlayerStatus())
	case http.MethodPost:
		var body struct {
			Action  string  `json:"action"`
			URL     string  `json:"url"`
			Player  string  `json:"player"`
			HistKey string  `json:"histKey"`
			Cmd     string  `json:"cmd"`
			Value   float64 `json:"value"`
			Mode    string  `json:"mode"`
		}
		raw, _ := io.ReadAll(io.LimitReader(r.Body, 1<<20))
		_ = json.Unmarshal(raw, &body)
		action := strings.TrimSpace(body.Action)
		if action == "" {
			action = "external"
		}
		switch action {
		case "external":
			if err := api.APIPlayerExternal(body.URL, body.Player); err != nil {
				writeAPIError(w, http.StatusBadGateway, err.Error())
				return
			}
			writeJSON(w, http.StatusOK, map[string]any{"ok": true})
		case "embed", "embed_play":
			if err := api.APIPlayerEmbed(body.URL, body.Player, body.HistKey); err != nil {
				writeAPIError(w, http.StatusBadGateway, err.Error())
				return
			}
			writeJSON(w, http.StatusOK, map[string]any{"ok": true})
		case "control":
			cmd := strings.TrimSpace(body.Cmd)
			if cmd == "" {
				writeAPIError(w, http.StatusBadRequest, "missing cmd")
				return
			}
			if err := api.APIPlayerControl(cmd, body.Value, body.Mode); err != nil {
				writeAPIError(w, http.StatusBadGateway, err.Error())
				return
			}
			writeJSON(w, http.StatusOK, map[string]any{"ok": true})
		default:
			writeAPIError(w, http.StatusBadRequest, "unknown action")
		}
	default:
		writeAPIError(w, http.StatusMethodNotAllowed, "method not allowed")
	}
}

func (s *Server) handleAPIv1Tools(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodOptions {
		writeJSON(w, http.StatusOK, map[string]any{"ok": true})
		return
	}
	if r.Method != http.MethodPost {
		writeAPIError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}
	api := s.content()
	if api == nil {
		writeAPIError(w, http.StatusServiceUnavailable, "content api unavailable")
		return
	}
	var body struct {
		Action string         `json:"action"`
		Params map[string]any `json:"params"`
	}
	_ = json.NewDecoder(io.LimitReader(r.Body, 1<<20)).Decode(&body)
	if strings.TrimSpace(body.Action) == "" {
		writeAPIError(w, http.StatusBadRequest, "missing action")
		return
	}
	out, err := api.APITools(body.Action, body.Params)
	if err != nil {
		writeAPIError(w, http.StatusBadRequest, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, out)
}

// handleAPIv1UIPoll Flutter 轮询爬虫 UiBridge / Util.notify 消息。
func (s *Server) handleAPIv1UIPoll(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodOptions {
		writeJSON(w, http.StatusOK, map[string]any{"ok": true})
		return
	}
	if r.Method != http.MethodGet {
		writeAPIError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}
	msgs := s.events.DrainPostMsg(hostclient.ScopeID())
	if msgs == nil {
		msgs = []string{}
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true, "messages": msgs})
}

// handleAPIv1UIReply Flutter 回传声明式窗口事件（等同 /uiReply）。
func (s *Server) handleAPIv1UIReply(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodOptions {
		writeJSON(w, http.StatusOK, map[string]any{"ok": true})
		return
	}
	if r.Method != http.MethodPost {
		writeAPIError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}
	if s.uiReply == nil {
		s.uiReply = newUIReplyStore()
	}
	var body struct {
		ID     string            `json:"id"`
		Action string            `json:"action"`
		Values map[string]string `json:"values"`
	}
	_ = json.NewDecoder(io.LimitReader(r.Body, 256<<10)).Decode(&body)
	id := strings.TrimSpace(body.ID)
	if id == "" {
		id = strings.TrimSpace(r.URL.Query().Get("id"))
	}
	if id == "" || strings.TrimSpace(body.Action) == "" {
		writeAPIError(w, http.StatusBadRequest, "missing id or action")
		return
	}
	payload, err := json.Marshal(map[string]any{
		"action": body.Action,
		"values": body.Values,
	})
	if err != nil {
		writeAPIError(w, http.StatusBadRequest, err.Error())
		return
	}
	s.uiReply.put(id, string(payload))
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

// handleAPIv1Cancel 打断进行中的详情/分类等 spider 请求（网盘扫码卡住后离开详情页）。
// body 可选：{"hard":bool,"thunder":bool}；缺省 soft + 停磁力。
func (s *Server) handleAPIv1Cancel(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodOptions {
		writeJSON(w, http.StatusOK, map[string]any{"ok": true})
		return
	}
	if r.Method != http.MethodPost {
		writeAPIError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}
	api := s.content()
	if api == nil {
		writeAPIError(w, http.StatusServiceUnavailable, "content api unavailable")
		return
	}
	opts := map[string]any{}
	if r.Body != nil {
		_ = json.NewDecoder(r.Body).Decode(&opts)
	}
	writeJSON(w, http.StatusOK, api.APICancelPending(opts))
}

func (s *Server) handleSessionPing(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodOptions {
		writeJSON(w, http.StatusOK, map[string]any{"ok": true})
		return
	}
	if r.Method != http.MethodPost {
		writeAPIError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}
	api := s.content()
	if api == nil {
		writeAPIError(w, http.StatusServiceUnavailable, "content api unavailable")
		return
	}
	writeJSON(w, http.StatusOK, api.APISessionPing())
}

func (s *Server) handleSessionLeave(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodOptions {
		writeJSON(w, http.StatusOK, map[string]any{"ok": true})
		return
	}
	if r.Method != http.MethodPost {
		writeAPIError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}
	api := s.content()
	if api == nil {
		writeAPIError(w, http.StatusServiceUnavailable, "content api unavailable")
		return
	}
	writeJSON(w, http.StatusOK, api.APISessionLeave())
}

// handleAPIv1Shutdown 仅本机可调用：优雅停引擎（会顺带杀 Java/Python）。
func (s *Server) handleAPIv1Shutdown(w http.ResponseWriter, r *http.Request) {
	if r.Method == http.MethodOptions {
		writeJSON(w, http.StatusOK, map[string]any{"ok": true})
		return
	}
	if r.Method != http.MethodPost {
		writeAPIError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}
	if !isLoopbackAddr(r.RemoteAddr) {
		writeAPIError(w, http.StatusForbidden, "shutdown only allowed from localhost")
		return
	}
	if !s.requestShutdown() {
		writeAPIError(w, http.StatusServiceUnavailable, "shutdown hook unavailable")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true, "stopping": true})
}

func isLoopbackAddr(remote string) bool {
	host := remote
	if h, _, err := net.SplitHostPort(remote); err == nil {
		host = h
	}
	ip := net.ParseIP(host)
	return ip != nil && ip.IsLoopback()
}
