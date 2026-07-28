package remote

import "sync"

// Flutter 上报的播放状态（供 /media 与遥控页展示）。
var (
	mediaMu    sync.RWMutex
	mediaStore = map[string]string{"state": "idle", "title": "未播放"}
)

func SetMediaStore(m map[string]string) {
	mediaMu.Lock()
	defer mediaMu.Unlock()
	mediaStore = map[string]string{
		"state": "idle",
		"title": "未播放",
	}
	for k, v := range m {
		mediaStore[k] = v
	}
}

func SnapshotMediaFromStore() map[string]string {
	mediaMu.RLock()
	defer mediaMu.RUnlock()
	out := make(map[string]string, len(mediaStore))
	for k, v := range mediaStore {
		out[k] = v
	}
	return out
}
