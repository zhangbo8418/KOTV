package server

import (
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"time"

	"github.com/bobo/KOTV/internal/database"
	"github.com/bobo/KOTV/internal/settings"
)

const maxSyncBody = 8 << 20 // 8 MiB

// SyncHandler 局域网同步回调。
type SyncHandler struct {
	ValidatePair func(code string) bool
	Export       func(typ string) (json.RawMessage, error)
	Import       func(typ string, mode int, body []byte) error
	// ImportTVTargets 导入 TV FormBody 的 targets JSON（已做 key 归一）。
	ImportTVTargets func(typ string, force bool, targetsJSON string) error
	// ExportTVForm 导出 TV 兼容的 form 字段（config/targets 或 targets/configs）。
	ExportTVForm func(typ string) (url.Values, error)
}

func (s *Server) SetSyncHandler(h *SyncHandler) {
	s.mu.Lock()
	s.syncHandler = h
	s.mu.Unlock()
}

func (s *Server) handleSync(w http.ResponseWriter, r *http.Request, q map[string]string) {
	s.mu.RLock()
	h := s.syncHandler
	s.mu.RUnlock()
	if h == nil {
		http.Error(w, "sync not available", http.StatusServiceUnavailable)
		return
	}
	typ := strings.TrimSpace(q["type"])
	if typ != "history" && typ != "keep" {
		http.Error(w, "invalid type", http.StatusBadRequest)
		return
	}
	mode, _ := strconv.Atoi(strings.TrimSpace(q["mode"]))
	if mode < 0 || mode > 2 {
		http.Error(w, "invalid mode", http.StatusBadRequest)
		return
	}
	pair := strings.TrimSpace(q["pair"])
	force := strings.EqualFold(strings.TrimSpace(q["force"]), "true")
	targets := strings.TrimSpace(q["targets"])
	deviceJSON := strings.TrimSpace(q["device"])
	isTV := targets != "" || deviceJSON != "" ||
		strings.TrimSpace(q["config"]) != "" || strings.TrimSpace(q["configs"]) != ""

	// —— TV 协议（FormBody：device/config/targets，无 pair）——
	if isTV && pair == "" {
		if err := s.handleTVSync(h, typ, mode, force, targets, deviceJSON); err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("OK"))
		return
	}

	// —— KOTV 配对协议 ——
	if h.ValidatePair == nil || pair == "" || !h.ValidatePair(pair) {
		http.Error(w, "invalid pair code", http.StatusForbidden)
		return
	}
	if mode == 0 {
		if h.Export == nil {
			http.Error(w, "export not available", http.StatusServiceUnavailable)
			return
		}
		data, err := h.Export(typ)
		if err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write(data)
		return
	}
	if h.Import == nil {
		http.Error(w, "import not available", http.StatusServiceUnavailable)
		return
	}
	body, err := io.ReadAll(io.LimitReader(r.Body, maxSyncBody))
	if err != nil {
		http.Error(w, "read body failed", http.StatusBadRequest)
		return
	}
	if len(body) == 0 {
		http.Error(w, "empty body", http.StatusBadRequest)
		return
	}
	if err := h.Import(typ, mode, body); err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write([]byte("OK"))
}

func (s *Server) handleTVSync(h *SyncHandler, typ string, mode int, force bool, targets, deviceJSON string) error {
	// mode 0/1：导入对方 targets；mode 0/2：把本机数据推回 device。
	if (mode == 0 || mode == 1) && targets != "" {
		if h.ImportTVTargets == nil {
			return fmt.Errorf("tv import not available")
		}
		if err := h.ImportTVTargets(typ, force, targets); err != nil {
			return err
		}
	}
	if (mode == 0 || mode == 2) && deviceJSON != "" {
		if h.ExportTVForm == nil {
			return fmt.Errorf("tv export not available")
		}
		form, err := h.ExportTVForm(typ)
		if err != nil {
			return err
		}
		go pushTVSync(deviceJSON, typ, form)
	}
	return nil
}

func pushTVSync(deviceJSON, typ string, form url.Values) {
	var dev struct {
		IP string `json:"ip"`
	}
	if err := json.Unmarshal([]byte(deviceJSON), &dev); err != nil || strings.TrimSpace(dev.IP) == "" {
		log.Printf("sync push: bad device json")
		return
	}
	base := strings.TrimRight(strings.TrimSpace(dev.IP), "/")
	endpoint := base + "/action?do=sync&mode=0&type=" + url.QueryEscape(typ)
	client := &http.Client{Timeout: 30 * time.Second}
	resp, err := client.PostForm(endpoint, form)
	if err != nil {
		log.Printf("sync push to %s: %v", base, err)
		return
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		b, _ := io.ReadAll(io.LimitReader(resp.Body, 512))
		log.Printf("sync push HTTP %d: %s", resp.StatusCode, string(b))
	}
}

// NewAppSyncHandler 构造默认同步处理器（兼容 KOTV pair + TV FormBody）。
func NewAppSyncHandler(db *database.DB, validatePair func(string) bool) *SyncHandler {
	return &SyncHandler{
		ValidatePair: validatePair,
		Export: func(typ string) (json.RawMessage, error) {
			switch typ {
			case "history":
				items, err := db.ListAllHistory()
				if err != nil {
					return nil, err
				}
				return json.Marshal(items)
			case "keep":
				items, err := db.ListAllKeep(database.KeepTypeVod)
				if err != nil {
					return nil, err
				}
				return json.Marshal(items)
			default:
				return nil, http.ErrNotSupported
			}
		},
		Import: func(typ string, mode int, body []byte) error {
			switch typ {
			case "history":
				var items []database.History
				if err := json.Unmarshal(body, &items); err != nil {
					return err
				}
				normalizeHistoryKeys(items)
				return db.ImportHistory(items, mode)
			case "keep":
				var items []database.Keep
				if err := json.Unmarshal(body, &items); err != nil {
					return err
				}
				return db.ImportKeep(items, mode)
			default:
				return http.ErrNotSupported
			}
		},
		ImportTVTargets: func(typ string, force bool, targetsJSON string) error {
			mode := 1
			if force {
				mode = 2
			}
			switch typ {
			case "history":
				var items []database.History
				if err := json.Unmarshal([]byte(targetsJSON), &items); err != nil {
					return err
				}
				normalizeHistoryKeys(items)
				return db.ImportHistory(items, mode)
			case "keep":
				var items []database.Keep
				if err := json.Unmarshal([]byte(targetsJSON), &items); err != nil {
					return err
				}
				return db.ImportKeep(items, mode)
			default:
				return http.ErrNotSupported
			}
		},
		ExportTVForm: func(typ string) (url.Values, error) {
			form := url.Values{}
			switch typ {
			case "history":
				items, err := db.ListAllHistory()
				if err != nil {
					return nil, err
				}
				for i := range items {
					items[i].Key = historyKeyToTV(items[i].Key)
				}
				b, err := json.Marshal(items)
				if err != nil {
					return nil, err
				}
				cfgURL := settings.Get(settings.VOD)
				cfg, _ := json.Marshal(map[string]any{"url": cfgURL, "type": 0})
				form.Set("config", string(cfg))
				form.Set("targets", string(b))
			case "keep":
				items, err := db.ListAllKeep(database.KeepTypeVod)
				if err != nil {
					return nil, err
				}
				b, err := json.Marshal(items)
				if err != nil {
					return nil, err
				}
				cfgURL := settings.Get(settings.VOD)
				cfgs, _ := json.Marshal([]map[string]any{{"url": cfgURL, "type": 0}})
				form.Set("targets", string(b))
				form.Set("configs", string(cfgs))
			default:
				return nil, http.ErrNotSupported
			}
			return form, nil
		},
	}
}

func normalizeHistoryKeys(items []database.History) {
	for i := range items {
		items[i].Key = historyKeyFromTV(items[i].Key)
		if items[i].Position < 0 {
			items[i].Position = 0
		}
		if items[i].Opening < 0 {
			items[i].Opening = 0
		}
		if items[i].Ending < 0 {
			items[i].Ending = 0
		}
	}
}

// historyKeyFromTV TV: site$$$vodId → KOTV: vodId@site
func historyKeyFromTV(key string) string {
	key = strings.TrimSpace(key)
	if key == "" {
		return ""
	}
	if strings.Contains(key, "$$$") {
		parts := strings.SplitN(key, "$$$", 2)
		if len(parts) == 2 && parts[0] != "" && parts[1] != "" {
			return parts[1] + "@" + parts[0]
		}
	}
	return key
}

func historyKeyToTV(key string) string {
	key = strings.TrimSpace(key)
	if i := strings.LastIndex(key, "@"); i > 0 {
		return key[i+1:] + "$$$" + key[:i]
	}
	return key
}
