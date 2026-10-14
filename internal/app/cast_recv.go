package app

import (
	"encoding/json"
	"log"
	"strings"

	"github.com/bobo/KOTV/internal/database"
	"github.com/bobo/KOTV/internal/remote"
	"github.com/bobo/KOTV/internal/server"
	"github.com/bobo/KOTV/internal/service"
	"github.com/bobo/KOTV/internal/settings"
)

// ApplyRemoteCast 处理局域网 /action?do=cast（手机端投到本机）。
func (a *App) ApplyRemoteCast(configJSON, historyJSON string) {
	if strings.TrimSpace(historyJSON) == "" {
		return
	}
	if err := a.ensureCastConfig(configJSON); err != nil {
		log.Printf("cast config: %v", err)
	}
	h, ok := parseCastHistory(historyJSON)
	if !ok {
		log.Printf("cast: 无法解析 history")
		return
	}
	_ = a.DB.SaveHistory(h)

	ep := strings.TrimSpace(h.EpisodeURL)
	// 可播直链（含对端公网化后的 /proxy/…）走 push 播放；目录项走详情。
	if ep != "" && server.MatchPushURL(ep) {
		title := strings.TrimSpace(h.VodName)
		if title == "" {
			title = "投屏播放"
		}
		flag := strings.TrimSpace(h.VodFlag)
		if flag == "" {
			flag = "推送"
		}
		remarks := strings.TrimSpace(h.VodRemarks)
		if remarks == "" {
			remarks = "1"
		}
		remote.DefaultQueue.PushOpen(remote.OpenCmd{
			Kind:     "play",
			Site:     service.PushAgentKey,
			ID:       ep,
			Name:     title,
			Pic:      h.VodPic,
			Flag:     flag,
			Remarks:  remarks,
			URL:      ep,
			Position: h.Position,
		}, "")
		remote.NotifyPush()
		return
	}

	vodID, siteKey := splitHistoryKey(h.Key)
	if strings.TrimSpace(vodID) == "" {
		return
	}
	remote.DefaultQueue.PushOpen(remote.OpenCmd{
		Kind:     "detail",
		Site:     siteKey,
		ID:       vodID,
		Name:     h.VodName,
		Pic:      h.VodPic,
		Flag:     h.VodFlag,
		Remarks:  h.VodRemarks,
		Position: h.Position,
	}, "")
	remote.NotifyPush()
}

func (a *App) ensureCastConfig(configJSON string) error {
	configJSON = strings.TrimSpace(configJSON)
	if configJSON == "" {
		return nil
	}
	var cfg struct {
		URL  string `json:"url"`
		Json string `json:"json"`
	}
	if err := json.Unmarshal([]byte(configJSON), &cfg); err != nil {
		return err
	}
	src := strings.TrimSpace(cfg.URL)
	if src == "" {
		src = strings.TrimSpace(cfg.Json)
	}
	if src == "" {
		return nil
	}
	cur := strings.TrimSpace(settings.Get(settings.VOD))
	if src == cur {
		return nil
	}
	settings.Set(settings.VOD, src)
	_ = settings.Save()
	return a.LoadVodSource(src)
}

type castHistoryDTO struct {
	Key        string  `json:"key"`
	VodPic     string  `json:"vodPic"`
	VodName    string  `json:"vodName"`
	VodFlag    string  `json:"vodFlag"`
	VodRemarks string  `json:"vodRemarks"`
	EpisodeURL string  `json:"episodeUrl"`
	Position   int64   `json:"position"`
	Duration   int64   `json:"duration"`
	Speed      float64 `json:"speed"`
	Opening    int64   `json:"opening"`
	Ending     int64   `json:"ending"`
}

func parseCastHistory(raw string) (database.History, bool) {
	var dto castHistoryDTO
	if err := json.Unmarshal([]byte(raw), &dto); err != nil {
		return database.History{}, false
	}
	key := normalizeHistoryKey(dto.Key)
	if key == "" && dto.EpisodeURL == "" {
		return database.History{}, false
	}
	if key == "" {
		key = "cast@" + dto.VodName
	}
	speed := dto.Speed
	if speed <= 0 {
		speed = 1
	}
	pos := dto.Position
	if pos < 0 {
		pos = 0
	}
	return database.History{
		Key:        key,
		VodPic:     dto.VodPic,
		VodName:    dto.VodName,
		VodFlag:    dto.VodFlag,
		VodRemarks: dto.VodRemarks,
		EpisodeURL: strings.TrimSpace(dto.EpisodeURL),
		Position:   pos,
		Duration:   dto.Duration,
		Speed:      speed,
		Opening:    max64(0, dto.Opening),
		Ending:     max64(0, dto.Ending),
	}, true
}

// normalizeHistoryKey 把外部 site@@@vodId@@@cid / site$$$vodId 归一成 KOTV 的 vodId@siteKey。
func normalizeHistoryKey(key string) string {
	key = strings.TrimSpace(key)
	if key == "" {
		return ""
	}
	if strings.Contains(key, "@@@") {
		parts := strings.Split(key, "@@@")
		if len(parts) >= 2 && parts[0] != "" && parts[1] != "" {
			return parts[1] + "@" + parts[0]
		}
	}
	if strings.Contains(key, "$$$") {
		parts := strings.SplitN(key, "$$$", 2)
		if len(parts) == 2 && parts[0] != "" && parts[1] != "" {
			return parts[1] + "@" + parts[0]
		}
	}
	return key
}

func splitHistoryKey(key string) (vodID, siteKey string) {
	if i := strings.LastIndex(key, "@"); i >= 0 {
		return key[:i], key[i+1:]
	}
	return key, ""
}

func max64(a, b int64) int64 {
	if a > b {
		return a
	}
	return b
}
