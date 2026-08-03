package remote

import (
	"strings"
	"sync"

	"github.com/bobo/KOTV/internal/hostclient"
)

// Flutter 上报的播放状态（供 /media 与遥控页展示）。
// 按 ScopeID 分桶：远端登录为 u:<userId>；本机未登录可为 c:<clientId> 或空桶。
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

// SnapshotMediaFor 返回指定 ScopeID/userId 的媒体快照；空则优先选正在播放的桶。
func SnapshotMediaFor(raw string) map[string]string {
	key := hostclient.NormalizeScopeKey(raw)
	mediaMu.RLock()
	defer mediaMu.RUnlock()
	if key != "" {
		out := copyMedia(mediaByClient[key])
		annotateScope(out, key)
		return out
	}
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
		out := copyMedia(mediaByClient[""])
		annotateScope(out, "")
		return out
	}
	out := copyMedia(mediaByClient[bestID])
	annotateScope(out, bestID)
	return out
}

// ListMediaClients 供遥控页选择目标用户（远端按 userId）。
func ListMediaClients() []map[string]string {
	mediaMu.RLock()
	defer mediaMu.RUnlock()
	out := make([]map[string]string, 0, len(mediaByClient))
	for id, src := range mediaByClient {
		item := copyMedia(src)
		annotateScope(item, id)
		out = append(out, item)
	}
	return out
}

func annotateScope(m map[string]string, scope string) {
	m["scopeId"] = scope
	// 兼容旧遥控页字段名
	m["clientId"] = scope
	if uid := hostclient.UserIDFromScope(scope); uid != "" {
		m["userId"] = uid
		if len(uid) > 8 {
			m["label"] = uid[:8]
		} else {
			m["label"] = uid
		}
	} else if scope == "" {
		m["label"] = "默认"
	} else if len(scope) > 10 {
		m["label"] = scope[:10]
	} else {
		m["label"] = scope
	}
}

func copyMedia(src map[string]string) map[string]string {
	if src == nil {
		return map[string]string{"state": "idle", "title": "未播放"}
	}
	out := make(map[string]string, len(src)+4)
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
