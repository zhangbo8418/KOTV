package source

import (
	"encoding/json"
	"net/url"
	"strings"

	"github.com/bobo/KOTV/internal/model"
)

// Info 专用源展开结果：可播地址 + 可选字幕/元数据。
type Info struct {
	URL     string
	Subs    []model.Sub
	Name    string
	Artwork string
	Desc    string
}

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
	case "tvbus", "jianpian", "tvbox-xg", "xg", "xgplay", "ftp":
		// ftp：荐片/xg 展开后的 P2P 路径。
		return true
	case "p2p", "p3p", "p4p", "p5p", "p6p", "p7p", "p8p", "p9p", "mitv":
		return true
	}
	host := strings.ToLower(u.Hostname())
	return strings.Contains(host, "youtube.com") || strings.Contains(host, "youtu.be")
}

// Fetch 把专用 scheme / YouTube 转成可播 HTTP（仅地址）。
func Fetch(playURL string, core json.RawMessage) (string, error) {
	info, err := FetchInfo(playURL, core)
	if err != nil {
		return "", err
	}
	return info.URL, nil
}

// FetchInfo 展开专用源，并带回字幕与标题/封面（YouTube 等）。
func FetchInfo(playURL string, core json.RawMessage) (Info, error) {
	return fetchPlatformInfo(strings.TrimSpace(playURL), core)
}

// Stop 停掉当前荐片/TVBus 任务。
func Stop() {
	stopPlatform()
}
