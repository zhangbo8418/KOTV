package server

import (
	"encoding/json"
	"net/http"
	"strconv"
	"strings"

	"github.com/bobo/KOTV/internal/database"
	"github.com/bobo/KOTV/internal/hostclient"
)

// SetLibraryDB 遥控片库列表用（历史/收藏）。
func (s *Server) SetLibraryDB(db *database.DB) {
	s.mu.Lock()
	s.libraryDB = db
	s.mu.Unlock()
}

func (s *Server) handleLibrary(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	s.mu.RLock()
	db := s.libraryDB
	s.mu.RUnlock()
	if db == nil {
		writeJSON(w, http.StatusServiceUnavailable, map[string]any{"ok": false, "error": "库未就绪"})
		return
	}
	typ := strings.ToLower(strings.TrimSpace(r.URL.Query().Get("type")))
	if typ == "" {
		typ = "history"
	}
	limit := 80
	if v := strings.TrimSpace(r.URL.Query().Get("limit")); v != "" {
		if n, err := strconv.Atoi(v); err == nil && n > 0 && n <= 500 {
			limit = n
		}
	}
	owner := libraryOwnerFromRequest(r)
	switch typ {
	case "history":
		items, err := db.ListHistory(owner, limit)
		if err != nil {
			writeJSON(w, http.StatusInternalServerError, map[string]any{"ok": false, "error": err.Error()})
			return
		}
		out := make([]map[string]any, 0, len(items))
		for _, h := range items {
			site, id := splitLibraryKey(h.Key)
			kind := "detail"
			url := strings.TrimSpace(h.EpisodeURL)
			if url == "" && (strings.HasPrefix(id, "http://") || strings.HasPrefix(id, "https://") || site == "push_agent") {
				kind = "play"
				if url == "" {
					url = id
				}
			}
			out = append(out, map[string]any{
				"key":        h.Key,
				"site":       site,
				"id":         id,
				"name":       h.VodName,
				"pic":        h.VodPic,
				"flag":       h.VodFlag,
				"remarks":    h.VodRemarks,
				"url":        url,
				"position":   h.Position,
				"duration":   h.Duration,
				"kind":       kind,
				"createTime": h.CreateTime,
			})
		}
		_ = json.NewEncoder(w).Encode(map[string]any{"ok": true, "type": typ, "owner": owner, "items": out})
	case "keep":
		items, err := db.ListKeep(owner, database.KeepTypeVod, limit)
		if err != nil {
			writeJSON(w, http.StatusInternalServerError, map[string]any{"ok": false, "error": err.Error()})
			return
		}
		out := make([]map[string]any, 0, len(items))
		for _, k := range items {
			site, id := splitLibraryKey(k.Key)
			out = append(out, map[string]any{
				"key":        k.Key,
				"site":       site,
				"id":         id,
				"name":       k.VodName,
				"pic":        k.VodPic,
				"flag":       k.VodFlag,
				"remarks":    k.VodRemarks,
				"url":        "",
				"position":   0,
				"duration":   0,
				"kind":       "detail",
				"createTime": k.CreateTime,
				"siteName":   k.SiteName,
			})
		}
		_ = json.NewEncoder(w).Encode(map[string]any{"ok": true, "type": typ, "owner": owner, "items": out})
	default:
		writeJSON(w, http.StatusBadRequest, map[string]any{"ok": false, "error": "type 仅支持 history / keep"})
	}
}

func libraryOwnerFromRequest(r *http.Request) string {
	scope := hostclient.ResolveScopeKey(
		r.URL.Query().Get("userId"),
		r.URL.Query().Get("scopeId"),
		first(r.URL.Query().Get("clientId"), r.Header.Get("X-Kotv-Client-Id")),
	)
	if u := hostclient.UserIDFromScope(scope); u != "" {
		return u
	}
	return ""
}

// splitLibraryKey：vodId@site 或 site$$$vodId → site, id。
func splitLibraryKey(key string) (site, id string) {
	key = strings.TrimSpace(key)
	if key == "" {
		return "", ""
	}
	if strings.Contains(key, "$$$") {
		parts := strings.SplitN(key, "$$$", 2)
		if len(parts) == 2 {
			return parts[0], parts[1]
		}
	}
	if i := strings.LastIndex(key, "@"); i > 0 {
		return key[i+1:], key[:i]
	}
	return "", key
}
