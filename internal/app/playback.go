package app

import (
	"fmt"
	"path"
	"strings"

	"github.com/bobo/KOTV/internal/database"
	"github.com/bobo/KOTV/internal/localproxy"
	"github.com/bobo/KOTV/internal/m3u8"
	"github.com/bobo/KOTV/internal/playproxy"
	"github.com/bobo/KOTV/internal/settings"
	"github.com/bobo/KOTV/internal/thunder"
)

// 本地媒体后缀（csp_Local / 推送绝对路径）。嗅探规则只认 http(s)，这里单独放行。
var localMediaExt = map[string]struct{}{
	".mp4": {}, ".mkv": {}, ".avi": {}, ".mov": {}, ".flv": {}, ".webm": {},
	".ts": {}, ".m2ts": {}, ".mts": {}, ".m4v": {}, ".wmv": {}, ".iso": {},
	".rmvb": {}, ".rm": {}, ".3gp": {}, ".f4v": {}, ".asf": {}, ".ogv": {},
	".mp3": {}, ".m4a": {}, ".aac": {}, ".flac": {}, ".wav": {}, ".ogg": {},
	".m3u8": {}, ".mpd": {},
}

// IsLocalMediaURL 是否为本地文件/内容 URI，应对齐 TV 直喂播放器，不要包 HTTP 代理。
func IsLocalMediaURL(u string) bool {
	u = strings.TrimSpace(u)
	if u == "" {
		return false
	}
	low := strings.ToLower(u)
	if strings.HasPrefix(low, "file:") || strings.HasPrefix(low, "content:") {
		return true
	}
	if strings.HasPrefix(u, "/") {
		ext := strings.ToLower(path.Ext(u))
		if ext == "" {
			return false
		}
		_, ok := localMediaExt[ext]
		return ok
	}
	return false
}

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
	if raw == "" || IsEphemeralPlayURL(raw) || IsLocalMediaURL(raw) {
		return raw
	}
	// TV UrlUtil.convert：proxy:// → http://127.0.0.1/proxy?...
	raw = localproxy.ConvertScheme(raw)
	// 「网盘经后端加速」：保留 jar /proxy（各平台原生库 / go / Java 多线程），不展开 CDN。
	if !settings.IsBackendProxyPlay() {
		// 夸克/UC 等把 CDN+Cookie 编进 /proxy?url=&header=：展开后走 /proxy/play 真流式。
		if media, hdrs, ok := playproxy.ExpandSpiderMediaProxy(raw, headers); ok {
			raw = media
			headers = hdrs
		}
	}
	port := 9978
	if a != nil && a.Server != nil {
		if p := a.Server.Port(); p > 0 {
			port = p
		}
	}
	playURL := raw
	if !thunder.Match(playURL) {
		// 仍须走 jar 的本地代理（如 m3u8 分片改写 / so 多线程）时，只改写对外可达根。
		if localproxy.IsSpiderProxyURL(playURL) {
			return playproxy.PublicizeURL(playURL)
		}
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
