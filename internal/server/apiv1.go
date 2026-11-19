package server

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strconv"
	"strings"
	"time"

	"github.com/bobo/KOTV/internal/auth"
	"github.com/bobo/KOTV/internal/database"
	"github.com/bobo/KOTV/internal/grouppolicy"
	"github.com/bobo/KOTV/internal/model"
	"github.com/bobo/KOTV/internal/playproxy"
	"github.com/bobo/KOTV/internal/remote"
	"github.com/bobo/KOTV/internal/usage"
)

// ContentAPI Flutter /api/v1 后端（由 app.App 实现，避免 server→app 循环依赖）。
type ContentAPI interface {
	APIHealth() map[string]any
	APIGetConfig() map[string]any
	APILoadConfig(source string) error
	APIRefreshConfig() error
	APISetHome(siteKey string) error
	APIHome() (map[string]any, error)
	APICategory(tid, pg string, extend map[string]string, siteKey string) (map[string]any, error)
	APIAction(siteKey, action string) (map[string]any, error)
	APIDetail(siteKey, vodID string) (map[string]any, error)
	APIDetailExpand(siteKey, vodID string, flags []map[string]any) (map[string]any, error)
	APIBtProgress() map[string]any
	APISearch(keyword string, siteKeys []string, exact bool, exclude []model.VodKey) (map[string]any, error)
	APIPlay(siteKey, vodID, flag, episodeURL string, episodeIndex, qualIdx int) (map[string]any, error)
	APIDanmakuLoad(ctx context.Context, src string, durationMs int64) (map[string]any, error)
	APIDanmakuSearch(ctx context.Context, name, episode string) (map[string]any, error)
	APIDanmakuAuto(ctx context.Context, siteKey, name, episode string, spiderSources []model.DanmakuItem) map[string]any
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
	APILiveLoad(index int, url string, force bool) (map[string]any, error)
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
	APIDownloadList() map[string]any
	APIDownloadEnqueue(body map[string]any) (map[string]any, error)
	APIDownloadCancel(id string) map[string]any
	APIDownloadPause(id string) map[string]any
	APIDownloadResume(id string) map[string]any
	APIDownloadPauseAll() map[string]any
	APIDownloadResumeAll() map[string]any
	APIDownloadRemove(id string, deleteFile bool) map[string]any
	APIDownloadClearFinished() map[string]any
	APIFsList(path string) (map[string]any, error)
	PurgeUserData(userID, username string)
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

func clientIDFromRequest(r *http.Request) string {
	if v := strings.TrimSpace(r.Header.Get("X-Kotv-Client-Id")); v != "" {
		return v
	}
	return strings.TrimSpace(r.URL.Query().Get("clientId"))
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.Header().Set("Access-Control-Allow-Origin", "*")
	w.Header().Set("Access-Control-Allow-Headers", "Content-Type, Authorization, X-Kotv-Client-Id, X-Kotv-Client-Platform, X-Kotv-Client-Arch, X-Kotv-Client-Version, X-Kotv-Protocol, X-Kotv-Engine-Base")
	w.Header().Set("Access-Control-Allow-Methods", "GET, POST, DELETE, OPTIONS")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}

func rejectUnlessPost(w http.ResponseWriter, r *http.Request) bool {
	if r.Method == http.MethodPost {
		return false
	}
	writeAPIError(w, http.StatusMethodNotAllowed, "method not allowed")
	return true
}

func rejectNoContent(w http.ResponseWriter, api ContentAPI) bool {
	if api != nil {
		return false
	}
	writeAPIError(w, http.StatusServiceUnavailable, "content api unavailable")
	return true
}

func rejectBadGateway(w http.ResponseWriter, err error) bool {
	if err == nil {
		return false
	}
	if rejectNeedAdminErr(w, err) {
		return true
	}
	writeAPIError(w, http.StatusBadGateway, err.Error())
	return true
}

func rejectNeedAdminErr(w http.ResponseWriter, err error) bool {
	if err == nil {
		return false
	}
	if errors.Is(err, ErrNeedAdmin) {
		writeAPIError(w, http.StatusForbidden, ErrNeedAdmin.Error())
		return true
	}
	return false
}

func rejectInternal(w http.ResponseWriter, err error) bool {
	if err == nil {
		return false
	}
	writeAPIError(w, http.StatusInternalServerError, err.Error())
	return true
}

func writeAPIError(w http.ResponseWriter, status int, msg string) {
	writeJSON(w, status, map[string]any{"ok": false, "error": msg})
}

func (s *Server) handleAPIv1Health(w http.ResponseWriter, r *http.Request) {
	h := map[string]any{"ok": true, "engine": "kotv", "ready": false}
	if api := s.content(); api != nil {
		h = api.APIHealth()
	}
	// 远端客户端据此判断是否同一套接口、加密账号密码，并记住这台后端。
	h["protocol"] = ProtocolVersion
	h["identity"] = auth.IdentityKey()
	writeJSON(w, http.StatusOK, h)
}

// handleAPIv1Net 缓冲浮层测速：代理累计下行字节（与播放器解耦，Traffic 思路）。
func (s *Server) handleAPIv1Net(w http.ResponseWriter, r *http.Request) {
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
	api := s.content()
	if rejectNoContent(w, api) {
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
		started := time.Now()
		repoName := s.configRemarkName(src, int64(database.ConfigTypeSite))
		if err := api.APILoadConfig(src); err != nil {
			recordUsage(r, "config_load", "repo", src, repoName, false, "load", started)
			if rejectNeedAdminErr(w, err) {
				return
			}
			writeAPIError(w, http.StatusBadRequest, err.Error())
			return
		}
		// 加载后可能刚写入备注名，再取一次
		if repoName == "" {
			repoName = s.configRemarkName(src, int64(database.ConfigTypeSite))
		}
		recordUsage(r, "config_load", "repo", src, repoName, true, "", started)
		writeJSON(w, http.StatusOK, api.APIGetConfig())
	default:
		writeAPIError(w, http.StatusMethodNotAllowed, "method not allowed")
	}
}

func (s *Server) handleAPIv1ConfigRefresh(w http.ResponseWriter, r *http.Request) {
	api := s.content()
	if rejectNoContent(w, api) {
		return
	}
	if rejectUnlessPost(w, r) {
		return
	}
	if err := api.APIRefreshConfig(); err != nil {
		writeAPIError(w, http.StatusBadRequest, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, api.APIGetConfig())
}

func (s *Server) handleAPIv1Sites(w http.ResponseWriter, r *http.Request) {
	api := s.content()
	if rejectNoContent(w, api) {
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
	api := s.content()
	if rejectNoContent(w, api) {
		return
	}
	started := time.Now()
	out, err := api.APIHome()
	ok := err == nil
	site := ""
	if out != nil {
		if v, _ := out["site"].(string); v != "" {
			site = v
		}
	}
	recordUsage(r, "site_home", "site", site, "", ok, errCode(err), started)
	if rejectBadGateway(w, err) {
		return
	}
	writeJSON(w, http.StatusOK, out)
}

func errCode(err error) string {
	if err == nil {
		return ""
	}
	return "err"
}

func (s *Server) handleAPIv1Category(w http.ResponseWriter, r *http.Request) {
	api := s.content()
	if rejectNoContent(w, api) {
		return
	}
	q := r.URL.Query()
	tid := q.Get("tid")
	pg := q.Get("pg")
	if pg == "" {
		pg = "1"
	}
	siteKey := q.Get("site")
	extend := map[string]string{}
	for k, vs := range q {
		if k == "tid" || k == "pg" || k == "site" {
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
			Site   string            `json:"site"`
			Extend map[string]string `json:"extend"`
		}
		_ = json.NewDecoder(r.Body).Decode(&body)
		if body.Tid != "" {
			tid = body.Tid
		}
		if body.Pg != "" {
			pg = body.Pg
		}
		if body.Site != "" {
			siteKey = body.Site
		}
		if body.Extend != nil {
			extend = body.Extend
		}
	}
	if tid == "" {
		writeAPIError(w, http.StatusBadRequest, "missing tid")
		return
	}
	out, err := api.APICategory(tid, pg, extend, siteKey)
	if rejectBadGateway(w, err) {
		return
	}
	writeJSON(w, http.StatusOK, out)
}

func (s *Server) handleAPIv1Action(w http.ResponseWriter, r *http.Request) {
	if rejectUnlessPost(w, r) {
		return
	}
	api := s.content()
	if rejectNoContent(w, api) {
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
	if rejectBadGateway(w, err) {
		return
	}
	writeJSON(w, http.StatusOK, out)
}

func (s *Server) handleAPIv1Detail(w http.ResponseWriter, r *http.Request) {
	api := s.content()
	if rejectNoContent(w, api) {
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
	if rejectBadGateway(w, err) {
		return
	}
	writeJSON(w, http.StatusOK, out)
}

func (s *Server) handleAPIv1DetailExpand(w http.ResponseWriter, r *http.Request) {
	api := s.content()
	if rejectNoContent(w, api) {
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
	if rejectBadGateway(w, err) {
		return
	}
	writeJSON(w, http.StatusOK, out)
}

func (s *Server) handleAPIv1BtProgress(w http.ResponseWriter, r *http.Request) {
	api := s.content()
	if rejectNoContent(w, api) {
		return
	}
	writeJSON(w, http.StatusOK, api.APIBtProgress())
}

func (s *Server) handleAPIv1Fs(w http.ResponseWriter, r *http.Request) {
	api := s.content()
	if rejectNoContent(w, api) {
		return
	}
	if r.Method != http.MethodGet {
		writeAPIError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}
	path := strings.TrimSpace(r.URL.Query().Get("path"))
	out, err := api.APIFsList(path)
	if rejectBadGateway(w, err) {
		return
	}
	writeJSON(w, http.StatusOK, out)
}

func (s *Server) handleAPIv1Download(w http.ResponseWriter, r *http.Request) {
	api := s.content()
	if rejectNoContent(w, api) {
		return
	}
	if r.Method == http.MethodGet {
		writeJSON(w, http.StatusOK, api.APIDownloadList())
		return
	}
	if rejectUnlessPost(w, r) {
		return
	}
	var body map[string]any
	_ = json.NewDecoder(r.Body).Decode(&body)
	if body == nil {
		body = map[string]any{}
	}
	action := strings.TrimSpace(r.URL.Query().Get("action"))
	if action == "" {
		action = strings.TrimSpace(fmt.Sprint(body["action"]))
	}
	switch action {
	case "", "enqueue":
		out, err := api.APIDownloadEnqueue(body)
		if rejectBadGateway(w, err) {
			return
		}
		writeJSON(w, http.StatusOK, out)
	case "cancel":
		id := strings.TrimSpace(fmt.Sprint(body["id"]))
		writeJSON(w, http.StatusOK, api.APIDownloadCancel(id))
	case "pause":
		id := strings.TrimSpace(fmt.Sprint(body["id"]))
		writeJSON(w, http.StatusOK, api.APIDownloadPause(id))
	case "resume", "start":
		id := strings.TrimSpace(fmt.Sprint(body["id"]))
		writeJSON(w, http.StatusOK, api.APIDownloadResume(id))
	case "pauseAll":
		writeJSON(w, http.StatusOK, api.APIDownloadPauseAll())
	case "resumeAll", "startAll":
		writeJSON(w, http.StatusOK, api.APIDownloadResumeAll())
	case "remove":
		id := strings.TrimSpace(fmt.Sprint(body["id"]))
		del := body["deleteFile"] == true || fmt.Sprint(body["deleteFile"]) == "true"
		writeJSON(w, http.StatusOK, api.APIDownloadRemove(id, del))
	case "clearFinished":
		writeJSON(w, http.StatusOK, api.APIDownloadClearFinished())
	case "list":
		writeJSON(w, http.StatusOK, api.APIDownloadList())
	default:
		writeAPIError(w, http.StatusBadRequest, "unknown download action")
	}
}

func (s *Server) handleAPIv1Search(w http.ResponseWriter, r *http.Request) {
	api := s.content()
	if rejectNoContent(w, api) {
		return
	}
	user := authUserFrom(r.Context())
	pol := grouppolicy.Resolve(user)
	if (user == nil || user.Role != auth.RoleAdmin) && !pol.Caps["allowSearch"] {
		writeAPIError(w, http.StatusForbidden, "当前分组未开放搜索")
		return
	}
	keyword := strings.TrimSpace(r.URL.Query().Get("wd"))
	var siteKeys []string
	var exact bool
	var exclude []model.VodKey
	if r.Method == http.MethodPost {
		var body struct {
			Keyword     string   `json:"keyword"`
			Wd          string   `json:"wd"`
			SiteKeys    []string `json:"sites"`
			Exact       bool     `json:"exact"`
			ExcludeSite string   `json:"excludeSite"`
			ExcludeID   string   `json:"excludeId"`
			Exclude     []struct {
				Site string `json:"site"`
				ID   string `json:"id"`
			} `json:"exclude"`
		}
		_ = json.NewDecoder(r.Body).Decode(&body)
		if body.Keyword != "" {
			keyword = body.Keyword
		} else if body.Wd != "" {
			keyword = body.Wd
		}
		siteKeys = body.SiteKeys
		exact = body.Exact
		for _, item := range body.Exclude {
			exclude = append(exclude, model.VodKey{Site: item.Site, ID: item.ID})
		}
		if strings.TrimSpace(body.ExcludeSite) != "" && strings.TrimSpace(body.ExcludeID) != "" {
			exclude = append(exclude, model.VodKey{Site: body.ExcludeSite, ID: body.ExcludeID})
		}
	}
	if keyword == "" {
		writeAPIError(w, http.StatusBadRequest, "missing keyword")
		return
	}
	started := time.Now()
	out, err := api.APISearch(keyword, siteKeys, exact, exclude)
	refName := ""
	if usage.SearchTermsEnabled() {
		refName = keyword
		if len(refName) > 64 {
			refName = refName[:64]
		}
	}
	recordUsage(r, "search", "q", "", refName, err == nil, errCode(err), started)
	if rejectBadGateway(w, err) {
		return
	}
	writeJSON(w, http.StatusOK, out)
}

func (s *Server) handleAPIv1Play(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost && r.Method != http.MethodGet {
		writeAPIError(w, http.StatusMethodNotAllowed, "method not allowed")
		return
	}
	api := s.content()
	if rejectNoContent(w, api) {
		return
	}
	siteKey := r.URL.Query().Get("site")
	vodID := r.URL.Query().Get("id")
	flag := r.URL.Query().Get("flag")
	ep := r.URL.Query().Get("url")
	epIdx := -1
	qualIdx := 0
	if v := r.URL.Query().Get("qual"); v != "" {
		qualIdx, _ = strconv.Atoi(v)
	}
	if v := r.URL.Query().Get("index"); v != "" {
		epIdx, _ = strconv.Atoi(v)
	}
	if r.Method == http.MethodPost {
		var body struct {
			Site    string `json:"site"`
			ID      string `json:"id"`
			Flag    string `json:"flag"`
			URL     string `json:"url"`
			Episode string `json:"episode"`
			Index   int    `json:"index"`
			Qual    int    `json:"qual"`
		}
		body.Index = -1
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
		if body.Index >= 0 {
			epIdx = body.Index
		}
		qualIdx = body.Qual
	}
	if strings.TrimSpace(ep) == "" && epIdx < 0 {
		writeAPIError(w, http.StatusBadRequest, "missing episode url")
		return
	}
	started := time.Now()
	out, err := api.APIPlay(siteKey, vodID, flag, ep, epIdx, qualIdx)
	refID := siteKey + "/" + vodID
	recordUsage(r, "play", "vod", refID, "", err == nil, errCode(err), started)
	if rejectBadGateway(w, err) {
		return
	}
	writeJSON(w, http.StatusOK, out)
}

// handleAPIv1Danmaku 弹幕：GET ?action=load&url=&duration=(毫秒) 拉取解析；POST action=search 手动搜索；
// POST action=auto 起播时决定弹幕源（body: site,name,episode,sources）。
func (s *Server) handleAPIv1Danmaku(w http.ResponseWriter, r *http.Request) {
	api := s.content()
	if rejectNoContent(w, api) {
		return
	}
	q := r.URL.Query()
	var body struct {
		URL     string              `json:"url"`
		Site    string              `json:"site"`
		Name    string              `json:"name"`
		Episode string              `json:"episode"`
		Sources []model.DanmakuItem `json:"sources"`
	}
	if r.Method == http.MethodPost {
		_ = json.NewDecoder(r.Body).Decode(&body)
	}
	pick := func(fromBody, key string) string {
		if v := strings.TrimSpace(fromBody); v != "" {
			return v
		}
		return strings.TrimSpace(q.Get(key))
	}
	switch q.Get("action") {
	case "", "load":
		durationMs, _ := strconv.ParseInt(q.Get("duration"), 10, 64)
		out, err := api.APIDanmakuLoad(r.Context(), pick(body.URL, "url"), durationMs)
		if rejectBadGateway(w, err) {
			return
		}
		writeJSON(w, http.StatusOK, out)
	case "search":
		out, err := api.APIDanmakuSearch(r.Context(), pick(body.Name, "name"), pick(body.Episode, "episode"))
		if rejectBadGateway(w, err) {
			return
		}
		writeJSON(w, http.StatusOK, out)
	case "auto":
		writeJSON(w, http.StatusOK, api.APIDanmakuAuto(r.Context(), pick(body.Site, "site"),
			pick(body.Name, "name"), pick(body.Episode, "episode"), body.Sources))
	default:
		writeAPIError(w, http.StatusBadRequest, "unknown action")
	}
}

func (s *Server) handleAPIv1RemotePoll(w http.ResponseWriter, r *http.Request) {
	api := s.content()
	if api == nil {
		writeJSON(w, http.StatusOK, map[string]any{
			"ok": true, "opens": []any{}, "controls": []any{}, "searches": []any{}, "refreshes": []any{}, "danmakuLive": []any{},
		})
		return
	}
	writeJSON(w, http.StatusOK, api.APIRemotePoll())
}

func (s *Server) handleAPIv1Media(w http.ResponseWriter, r *http.Request) {
	api := s.content()
	if rejectNoContent(w, api) {
		return
	}
	if r.Method == http.MethodGet {
		writeJSON(w, http.StatusOK, map[string]any{"ok": true, "media": remote.SnapshotMediaFromStore()})
		return
	}
	if rejectUnlessPost(w, r) {
		return
	}
	var body map[string]string
	_ = json.NewDecoder(io.LimitReader(r.Body, 1<<20)).Decode(&body)
	api.APISetMedia(body)
	writeJSON(w, http.StatusOK, map[string]any{"ok": true})
}

func (s *Server) handleAPIv1Repos(w http.ResponseWriter, r *http.Request) {
	api := s.content()
	if rejectNoContent(w, api) {
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
			// 共享仓列表：删改需管理员；普通远端只选仓（loadConfig / setting.vod）。
			if rejectUnlessAdmin(w, r) {
				return
			}
			if err := api.APIEditRepo(oldURL, newURL, body.Name); err != nil {
				writeAPIError(w, http.StatusBadRequest, err.Error())
				return
			}
			writeJSON(w, http.StatusOK, map[string]any{"ok": true})
		default:
			writeAPIError(w, http.StatusBadRequest, "unknown action")
		}
	case http.MethodDelete:
		if rejectUnlessAdmin(w, r) {
			return
		}
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
	api := s.content()
	if rejectNoContent(w, api) {
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
			if rejectNeedAdminErr(w, err) {
				return
			}
			writeAPIError(w, http.StatusBadRequest, err.Error())
			return
		}
		writeJSON(w, http.StatusOK, api.APIGetSettings())
	default:
		writeAPIError(w, http.StatusMethodNotAllowed, "method not allowed")
	}
}

func (s *Server) handleAPIv1Live(w http.ResponseWriter, r *http.Request) {
	api := s.content()
	if rejectNoContent(w, api) {
		return
	}
	user := authUserFrom(r.Context())
	pol := grouppolicy.Resolve(user)
	if user == nil || user.Role != auth.RoleAdmin {
		if !pol.Caps["allowLive"] {
			writeAPIError(w, http.StatusForbidden, "当前分组未开放直播")
			return
		}
	}
	if r.Method == http.MethodGet {
		writeJSON(w, http.StatusOK, api.APILiveSources())
		return
	}
	if rejectUnlessPost(w, r) {
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
		Force    bool   `json:"force"`
	}
	_ = json.NewDecoder(io.LimitReader(r.Body, 1<<20)).Decode(&body)
	switch strings.ToLower(strings.TrimSpace(body.Action)) {
	case "", "sources":
		writeJSON(w, http.StatusOK, api.APILiveSources())
	case "load":
		started := time.Now()
		liveURL := strings.TrimSpace(body.URL)
		liveName := s.configRemarkName(liveURL, int64(database.ConfigTypeLive))
		out, err := api.APILiveLoad(body.Index, body.URL, body.Force)
		if liveURL == "" && out != nil {
			liveURL = strings.TrimSpace(fmt.Sprint(out["url"]))
		}
		if liveName == "" && liveURL != "" {
			liveName = s.configRemarkName(liveURL, int64(database.ConfigTypeLive))
		}
		if liveName == "" && out != nil {
			if n := strings.TrimSpace(fmt.Sprint(out["name"])); n != "" && n != liveURL {
				liveName = n
			}
		}
		recordUsage(r, "live_load", "live", liveURL, liveName, err == nil, errCode(err), started)
		if rejectBadGateway(w, err) {
			return
		}
		writeJSON(w, http.StatusOK, out)
	case "play":
		started := time.Now()
		out, err := api.APILivePlay(body.Group, body.Channel, body.Line)
		recordUsage(r, "live_play", "live", fmt.Sprintf("%d/%d", body.Group, body.Channel), "", err == nil, errCode(err), started)
		if rejectBadGateway(w, err) {
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
		started := time.Now()
		out, err := api.APILiveEPG(body.Group, body.Channel)
		recordUsage(r, "live_epg", "live", fmt.Sprintf("%d/%d", body.Group, body.Channel), "", err == nil, errCode(err), started)
		if rejectBadGateway(w, err) {
			return
		}
		writeJSON(w, http.StatusOK, out)
	case "delete":
		// 共享直播列表：删改需管理员；普通远端只设 setting.live / load。
		if rejectUnlessAdmin(w, r) {
			return
		}
		if err := api.APIDeleteLive(body.URL); err != nil {
			writeAPIError(w, http.StatusBadRequest, err.Error())
			return
		}
		writeJSON(w, http.StatusOK, map[string]any{"ok": true})
	case "edit", "rename":
		if rejectUnlessAdmin(w, r) {
			return
		}
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
		started := time.Now()
		out, err := api.APILiveCatchup(body.Group, body.Channel, body.Day, body.Prog)
		recordUsage(r, "live_catchup", "live", fmt.Sprintf("%d/%d", body.Group, body.Channel), "", err == nil, errCode(err), started)
		if rejectBadGateway(w, err) {
			return
		}
		writeJSON(w, http.StatusOK, out)
	default:
		writeAPIError(w, http.StatusBadRequest, "unknown action")
	}
}

func (s *Server) handleAPIv1Player(w http.ResponseWriter, r *http.Request) {
	api := s.content()
	if rejectNoContent(w, api) {
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
			if err := api.APIPlayerExternal(body.URL, body.Player); rejectBadGateway(w, err) {
				return
			}
			writeJSON(w, http.StatusOK, map[string]any{"ok": true})
		case "embed", "embed_play":
			if err := api.APIPlayerEmbed(body.URL, body.Player, body.HistKey); rejectBadGateway(w, err) {
				return
			}
			writeJSON(w, http.StatusOK, map[string]any{"ok": true})
		case "control":
			cmd := strings.TrimSpace(body.Cmd)
			if cmd == "" {
				writeAPIError(w, http.StatusBadRequest, "missing cmd")
				return
			}
			if err := api.APIPlayerControl(cmd, body.Value, body.Mode); rejectBadGateway(w, err) {
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
	if rejectUnlessPost(w, r) {
		return
	}
	api := s.content()
	if rejectNoContent(w, api) {
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
		if rejectNeedAdminErr(w, err) {
			return
		}
		writeAPIError(w, http.StatusBadRequest, err.Error())
		return
	}
	writeJSON(w, http.StatusOK, out)
}

// handleAPIv1Cancel 打断进行中的详情/分类等 spider 请求（网盘扫码卡住后离开详情页）。
// body 可选：{"hard":bool,"thunder":bool}；缺省 soft + 停磁力。
func (s *Server) handleAPIv1Cancel(w http.ResponseWriter, r *http.Request) {
	if rejectUnlessPost(w, r) {
		return
	}
	api := s.content()
	if rejectNoContent(w, api) {
		return
	}
	opts := map[string]any{}
	if r.Body != nil {
		_ = json.NewDecoder(r.Body).Decode(&opts)
	}
	writeJSON(w, http.StatusOK, api.APICancelPending(opts))
}

func (s *Server) handleSessionPing(w http.ResponseWriter, r *http.Request) {
	api, ok := s.requirePostContent(w, r)
	if !ok {
		return
	}
	out := api.APISessionPing()
	recordUsage(r, "ping", "session", "", "", true, "", time.Time{})
	if u := authUserFrom(r.Context()); u != nil {
		usage.TouchDevice(u, r)
	}
	// 低频清理：约每 64 次 ping 扫一次
	if time.Now().Unix()%64 == 0 {
		go usage.MaybePurge()
	}
	writeJSON(w, http.StatusOK, out)
}

func (s *Server) handleSessionLeave(w http.ResponseWriter, r *http.Request) {
	api, ok := s.requirePostContent(w, r)
	if !ok {
		return
	}
	writeJSON(w, http.StatusOK, api.APISessionLeave())
}

func (s *Server) requirePostContent(w http.ResponseWriter, r *http.Request) (ContentAPI, bool) {
	if rejectUnlessPost(w, r) {
		return nil, false
	}
	api := s.content()
	if rejectNoContent(w, api) {
		return nil, false
	}
	return api, true
}

// handleAPIv1Shutdown 仅本机可调用：优雅停引擎（会顺带杀 Java/Python）。
func (s *Server) handleAPIv1Shutdown(w http.ResponseWriter, r *http.Request) {
	if rejectUnlessPost(w, r) {
		return
	}
	if !s.requestShutdown() {
		writeAPIError(w, http.StatusServiceUnavailable, "shutdown hook unavailable")
		return
	}
	writeJSON(w, http.StatusOK, map[string]any{"ok": true, "stopping": true})
}
