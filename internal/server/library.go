package server

import (
	"encoding/json"
	"io"
	"net/http"
	"strconv"
	"strings"
	"time"

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
	owner := libraryOwnerFromRequest(r)

	if r.Method == http.MethodPost {
		s.handleLibraryWrite(w, r, db, owner)
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
	case "liveKeep", "livefav":
		items, err := db.ListKeepLive(owner)
		if err != nil {
			writeJSON(w, http.StatusInternalServerError, map[string]any{"ok": false, "error": err.Error()})
			return
		}
		names := make([]string, 0, len(items))
		for _, k := range items {
			n := strings.TrimSpace(k.VodName)
			if n == "" {
				n = strings.TrimSpace(k.Key)
			}
			if n != "" {
				names = append(names, n)
			}
		}
		_ = json.NewEncoder(w).Encode(map[string]any{"ok": true, "type": "liveKeep", "owner": owner, "names": names, "items": items})
	default:
		writeJSON(w, http.StatusBadRequest, map[string]any{"ok": false, "error": "type 仅支持 history / keep / liveKeep"})
	}
}

func (s *Server) handleLibraryWrite(w http.ResponseWriter, r *http.Request, db *database.DB, owner string) {
	var body struct {
		Action string            `json:"action"`
		Type   string            `json:"type"`
		Item   *database.History `json:"item"`
		Keep   *database.Keep    `json:"keep"`
		Name   string            `json:"name"`
		Key    string            `json:"key"`
		Names  []string          `json:"names"`
	}
	_ = json.NewDecoder(io.LimitReader(r.Body, 1<<20)).Decode(&body)
	action := strings.ToLower(strings.TrimSpace(body.Action))
	typ := strings.ToLower(strings.TrimSpace(body.Type))
	switch action {
	case "savehistory":
		if body.Item == nil || strings.TrimSpace(body.Item.Key) == "" {
			writeJSON(w, http.StatusBadRequest, map[string]any{"ok": false, "error": "missing item"})
			return
		}
		if err := db.SaveHistory(owner, *body.Item); err != nil {
			writeJSON(w, http.StatusInternalServerError, map[string]any{"ok": false, "error": err.Error()})
			return
		}
		writeJSON(w, http.StatusOK, map[string]any{"ok": true})
	case "clearhistory":
		if err := db.ClearHistory(owner); err != nil {
			writeJSON(w, http.StatusInternalServerError, map[string]any{"ok": false, "error": err.Error()})
			return
		}
		writeJSON(w, http.StatusOK, map[string]any{"ok": true})
	case "deletehistory":
		key := strings.TrimSpace(body.Key)
		if key == "" && body.Item != nil {
			key = body.Item.Key
		}
		if err := db.DeleteHistory(owner, key); err != nil {
			writeJSON(w, http.StatusInternalServerError, map[string]any{"ok": false, "error": err.Error()})
			return
		}
		writeJSON(w, http.StatusOK, map[string]any{"ok": true})
	case "togglekeep":
		if body.Keep == nil || strings.TrimSpace(body.Keep.Key) == "" {
			writeJSON(w, http.StatusBadRequest, map[string]any{"ok": false, "error": "missing keep"})
			return
		}
		k := *body.Keep
		if k.Type == 0 && (typ == "livekeep" || typ == "livefav") {
			k.Type = database.KeepTypeLive
		}
		kept, err := db.ToggleKeep(owner, k)
		if err != nil {
			writeJSON(w, http.StatusInternalServerError, map[string]any{"ok": false, "error": err.Error()})
			return
		}
		writeJSON(w, http.StatusOK, map[string]any{"ok": true, "kept": kept})
	case "clearkeep":
		if typ == "livekeep" || typ == "livefav" {
			items, _ := db.ListKeepLive(owner)
			for _, it := range items {
				_ = db.DeleteKeep(owner, it.Key)
			}
		} else {
			_ = db.ImportKeep(owner, nil, 2)
		}
		writeJSON(w, http.StatusOK, map[string]any{"ok": true})
	case "deletekeep":
		if err := db.DeleteKeep(owner, strings.TrimSpace(body.Key)); err != nil {
			writeJSON(w, http.StatusInternalServerError, map[string]any{"ok": false, "error": err.Error()})
			return
		}
		writeJSON(w, http.StatusOK, map[string]any{"ok": true})
	case "togglelivefav":
		ch := strings.TrimSpace(body.Name)
		if ch == "" {
			writeJSON(w, http.StatusBadRequest, map[string]any{"ok": false, "error": "missing name"})
			return
		}
		k := database.Keep{
			Key:        database.KeepLiveKey("live", ch),
			VodName:    ch,
			Type:       database.KeepTypeLive,
			CreateTime: time.Now().UnixMilli(),
		}
		kept, err := db.ToggleKeep(owner, k)
		if err != nil {
			writeJSON(w, http.StatusInternalServerError, map[string]any{"ok": false, "error": err.Error()})
			return
		}
		writeJSON(w, http.StatusOK, map[string]any{"ok": true, "kept": kept})
	case "replacelivefav":
		items, _ := db.ListKeepLive(owner)
		for _, it := range items {
			_ = db.DeleteKeep(owner, it.Key)
		}
		for _, ch := range body.Names {
			ch = strings.TrimSpace(ch)
			if ch == "" {
				continue
			}
			_, _ = db.ToggleKeep(owner, database.Keep{
				Key:        database.KeepLiveKey("live", ch),
				VodName:    ch,
				Type:       database.KeepTypeLive,
				CreateTime: time.Now().UnixMilli(),
			})
		}
		writeJSON(w, http.StatusOK, map[string]any{"ok": true})
	default:
		writeJSON(w, http.StatusBadRequest, map[string]any{"ok": false, "error": "unknown action"})
	}
}

func libraryOwnerFromRequest(r *http.Request) string {
	if u := hostclient.DataOwner(); u != "" {
		return u
	}
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
