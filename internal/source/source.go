package source

import (
	"encoding/json"
	"net/url"
	"strings"
)

// Match 是否为荐片 / TVBus 专用播放地址（需 Native 转 HTTP）。
func Match(raw string) bool {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return false
	}
	u, err := url.Parse(raw)
	if err != nil {
		return false
	}
	switch strings.ToLower(u.Scheme) {
	case "tvbus", "jianpian", "tvbox-xg", "xg", "xgplay":
		return true
	default:
		return false
	}
}

// Fetch 把专用 scheme 转成可播 HTTP。桌面返回错误；Android 走 127.0.0.1:9979。
func Fetch(playURL string, core json.RawMessage) (string, error) {
	return fetchPlatform(strings.TrimSpace(playURL), core)
}

// Stop 停掉当前荐片/TVBus 任务。
func Stop() {
	stopPlatform()
}
