package app

import (
	"fmt"
	"strings"

	"github.com/bobo/KOTV/internal/database"
	"github.com/bobo/KOTV/internal/m3u8"
	"github.com/bobo/KOTV/internal/playproxy"
	"github.com/bobo/KOTV/internal/thunder"
)

// IsEphemeralPlayURL 是否为进程内临时代理地址（不应写入历史或跨会话复用）。
func IsEphemeralPlayURL(u string) bool {
	u = strings.ToLower(strings.TrimSpace(u))
	return strings.Contains(u, "/proxy/cached_m3u8") ||
		strings.Contains(u, "/proxy/play?") ||
		strings.Contains(u, "/proxy/bt/")
}

// PreparePlaybackURL 将媒体直链转为当前会话可播地址（m3u8 过滤缓存 + header 代理）。
func (a *App) PreparePlaybackURL(raw string, headers map[string]string) string {
	raw = strings.TrimSpace(raw)
	if raw == "" || IsEphemeralPlayURL(raw) {
		return raw
	}
	port := 9978
	if a != nil && a.Server != nil {
		if p := a.Server.Port(); p > 0 {
			port = p
		}
	}
	playURL := raw
	if !thunder.Match(playURL) {
		if resolved, err := m3u8.ResolveForPlayback(playURL, headers, port); err == nil && resolved != "" {
			playURL = resolved
		}
		playURL = playproxy.Register(playURL, headers)
	}
	return playproxy.PublicizeURL(playURL)
}

// PlayHistory 用历史里保存的原始媒体地址起播（会重新走 m3u8/代理，不依赖旧缓存 id）。
func (a *App) PlayHistory(h database.History) error {
	if strings.TrimSpace(h.EpisodeURL) == "" {
		return fmt.Errorf("历史无播放地址")
	}
	if IsEphemeralPlayURL(h.EpisodeURL) {
		return fmt.Errorf("历史地址已过期")
	}
	url := a.PreparePlaybackURL(h.EpisodeURL, nil)
	if url == "" || IsEphemeralPlayURL(url) {
		return fmt.Errorf("无法准备播放地址")
	}
	return PlayURLWithHistory(url, h.Key)
}
