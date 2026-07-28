package remote

import "sync"

// Handlers 由 UI 层注册，把 HTTP 遥控指令桥接到当前前端。
type Handlers struct {
	OnSearch    func(keyword string)
	OnPush      func()
	OnControl   func(typ string, seekMs int64)
	MediaState  func() map[string]string
}

var (
	mu       sync.RWMutex
	handlers Handlers
)

func SetHandlers(h Handlers) {
	mu.Lock()
	handlers = h
	mu.Unlock()
}

func get() Handlers {
	mu.RLock()
	defer mu.RUnlock()
	return handlers
}

func NotifySearch(keyword string) {
	if fn := get().OnSearch; fn != nil {
		fn(keyword)
	}
}

func NotifyPush() {
	if fn := get().OnPush; fn != nil {
		fn()
	}
}

func NotifyControl(typ string, seekMs int64) {
	if fn := get().OnControl; fn != nil {
		fn(typ, seekMs)
	}
}

func SnapshotMedia() map[string]string {
	if fn := get().MediaState; fn != nil {
		if m := fn(); m != nil {
			return m
		}
	}
	return map[string]string{"state": "idle", "title": "未播放"}
}
