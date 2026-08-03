package remote

import (
	"strings"
	"sync"

	"github.com/bobo/KOTV/internal/hostclient"
)

// Flutter 上报的播放状态（供 /media 与遥控页展示）。
// 按 clientId 分桶；空 clientId 走默认桶（桌面单用户兼容）。
var (
	mediaMu       sync.RWMutex
	mediaByClient = map[string]map[string]string{}
)

func mediaKey() string {
	return hostclient.ScopeID()
}

func SetMediaStore(m map[string]string) {
	key := mediaKey()
	cp := map[string]string{
		"state": "idle",
		"title": "未播放",
	}
	for k, v := range m {
		cp[k] = v
	}
	mediaMu.Lock()
	mediaByClient[key] = cp
	mediaMu.Unlock()
	if key != "" {
		DefaultQueue.Remember(key)
	}
}

func SnapshotMediaFromStore() map[string]string {
	return SnapshotMediaFor(mediaKey())
}

// SnapshotMediaFor 返回指定客户端的媒体快照；clientID 为空时优先选正在播放的桶。
func SnapshotMediaFor(clientID string) map[string]string {
	clientID = strings.TrimSpace(clientID)
	mediaMu.RLock()
	defer mediaMu.RUnlock()
	if clientID != "" {
		return copyMedia(mediaByClient[clientID])
	}
	// 无指定：优先 playing，其次非 idle，最后空桶
	bestID := ""
	bestScore := -1
	for id, src := range mediaByClient {
		score := 0
		st := strings.ToLower(strings.TrimSpace(src["state"]))
		switch st {
		case "playing":
			score = 3
		case "paused":
			score = 2
		case "idle", "":
			score = 0
		default:
			score = 1
		}
		if score > bestScore {
			bestScore = score
			bestID = id
		}
	}
	if bestScore <= 0 {
		return copyMedia(mediaByClient[""])
	}
	out := copyMedia(mediaByClient[bestID])
	if bestID != "" {
		out["clientId"] = bestID
	}
	return out
}

// ListMediaClients 供遥控页选择目标客户端。
func ListMediaClients() []map[string]string {
	mediaMu.RLock()
	defer mediaMu.RUnlock()
	out := make([]map[string]string, 0, len(mediaByClient))
	for id, src := range mediaByClient {
		item := copyMedia(src)
		item["clientId"] = id
		if id == "" {
			item["label"] = "默认"
		} else if len(id) > 8 {
			item["label"] = id[:8]
		} else {
			item["label"] = id
		}
		out = append(out, item)
	}
	return out
}

func copyMedia(src map[string]string) map[string]string {
	if src == nil {
		return map[string]string{"state": "idle", "title": "未播放"}
	}
	out := make(map[string]string, len(src)+2)
	for k, v := range src {
		out[k] = v
	}
	if _, ok := out["state"]; !ok {
		out["state"] = "idle"
	}
	if _, ok := out["title"]; !ok {
		out["title"] = "未播放"
	}
	return out
}
