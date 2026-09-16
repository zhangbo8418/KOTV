package source

import (
	"encoding/json"
	"net/url"
	"strings"
)

// Match 是否为荐片 / TVBus / YouTube 等需预处理的播放地址。
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
	case "p2p", "p3p", "p4p", "p5p", "p6p", "p7p", "p8p", "p9p", "mitv":
		return true
	}
	host := strings.ToLower(u.Hostname())
	return strings.Contains(host, "youtube.com") || strings.Contains(host, "youtu.be")
}

// Fetch 把专用 scheme / YouTube 转成可播 HTTP。
// Android：荐片 / TVBus / Force / NewPipe YouTube。
// 桌面：YouTube 走 yt-dlp；荐片 / TVBus / Force 仅安卓。
func Fetch(playURL string, core json.RawMessage) (string, error) {
	return fetchPlatform(strings.TrimSpace(playURL), core)
}

// Stop 停掉当前荐片/TVBus 任务。
func Stop() {
	stopPlatform()
}
