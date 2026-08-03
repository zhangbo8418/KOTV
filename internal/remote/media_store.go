package remote

import (
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
	return hostclient.Current()
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
}

func SnapshotMediaFromStore() map[string]string {
	key := mediaKey()
	mediaMu.RLock()
	defer mediaMu.RUnlock()
	src := mediaByClient[key]
	if src == nil {
		return map[string]string{"state": "idle", "title": "未播放"}
	}
	out := make(map[string]string, len(src))
	for k, v := range src {
		out[k] = v
	}
	return out
}
