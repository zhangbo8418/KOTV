package m3u8

import (
	"sync"
	"time"
)

// RollingPlaylistPath 每次 GET 都重新向上游拉取的播放列表。
const RollingPlaylistPath = "/proxy/rolling_m3u8"

type rollingEntry struct {
	URL       string
	Headers   map[string]string
	ExpiresAt time.Time
}

var (
	rollingMu      sync.Mutex
	rollingEntries = map[string]rollingEntry{}
)

// RegisterRolling 登记选中的媒体列表。之后每次读取都重新拉取并给切片带上请求头。
func RegisterRolling(mediaURL string, headers map[string]string) string {
	id := randomID()
	cp := make(map[string]string, len(headers))
	for k, v := range headers {
		cp[k] = v
	}
	now := time.Now()
	rollingMu.Lock()
	for k, e := range rollingEntries {
		if now.After(e.ExpiresAt) {
			delete(rollingEntries, k)
		}
	}
	if len(rollingEntries) >= rollingMax {
		n := len(rollingEntries) / 2
		for k := range rollingEntries {
			if n <= 0 {
				break
			}
			delete(rollingEntries, k)
			n--
		}
	}
	rollingEntries[id] = rollingEntry{
		URL:       mediaURL,
		Headers:   cp,
		ExpiresAt: now.Add(6 * time.Hour),
	}
	rollingMu.Unlock()
	return id
}

const rollingMax = 256

// ClearRolling 清空滚动 m3u8 登记表（清理缓存工具）。
func ClearRolling() {
	rollingMu.Lock()
	rollingEntries = map[string]rollingEntry{}
	rollingMu.Unlock()
}

// ServeRolling 重新拉取已登记的媒体列表，绝对化后把带头切片改成代理地址。
func ServeRolling(id string) (string, bool) {
	if id == "" {
		return "", false
	}
	rollingMu.Lock()
	e, ok := rollingEntries[id]
	if ok && time.Now().After(e.ExpiresAt) {
		delete(rollingEntries, id)
		ok = false
	}
	rollingMu.Unlock()
	if !ok {
		return "", false
	}
	content, err := fetch(e.URL, e.Headers)
	if err != nil || content == "" {
		return "", false
	}
	content = absolutizeURIs(content, e.URL)
	content = absolutizeTagURIs(content, e.URL)
	content = proxyMediaURIs(content, e.Headers)
	return content, true
}
