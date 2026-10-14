package app

import (
	"fmt"
	"net"
	"net/url"
	"path"
	"path/filepath"
	"strings"

	"github.com/bobo/KOTV/internal/database"
	"github.com/bobo/KOTV/internal/hostclient"
	"github.com/bobo/KOTV/internal/localproxy"
	"github.com/bobo/KOTV/internal/m3u8"
	"github.com/bobo/KOTV/internal/paths"
	"github.com/bobo/KOTV/internal/playproxy"
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

// IsLocalMediaURL 是否为本地文件/内容 URI；是则直喂播放器，不要包 HTTP 代理。
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
		strings.Contains(u, "/proxy/rolling_m3u8") ||
		strings.Contains(u, "/proxy/play?") ||
		strings.Contains(u, "/proxy/hls/") ||
		strings.Contains(u, "/proxy/bt/")
}

// PreparePlaybackURL 将媒体直链转为当前会话可播地址（m3u8 过滤缓存 + header 代理）。
func (a *App) PreparePlaybackURL(raw string, headers map[string]string) string {
	play, _ := a.PreparePlayback(raw, headers)
	return play
}

// PreparePlayback 的第二个返回值是能自己带请求头的播放器要打开的站点地址。
// 为空时，这类播放器也打开第一个返回值。
func (a *App) PreparePlayback(raw string, headers map[string]string) (string, string) {
	return a.preparePlayback(raw, headers, true)
}

// PreparePlaybackListed 直播列表批量用：只做代理/公网化，不拉每路 m3u8。
// 广告过滤在 livePlay / 点播起播时再 Resolve；列表里上百路绝对不能串行抓。
func (a *App) PreparePlaybackListed(raw string, headers map[string]string) (string, string) {
	return a.preparePlayback(raw, headers, false)
}

func (a *App) preparePlayback(raw string, headers map[string]string, resolveM3U8 bool) (string, string) {
	raw = strings.TrimSpace(raw)
	if raw == "" || IsEphemeralPlayURL(raw) {
		return raw, ""
	}
	if IsLocalMediaURL(raw) {
		return exposeLocalFile(raw), ""
	}
	// convert：proxy:// → http://127.0.0.1/proxy?...
	raw = localproxy.ConvertScheme(raw)
	// 远端才把网盘类 url+header 展开成 CDN→/proxy/play；本机保持 /proxy→jar。
	if playproxy.ShouldExpandSpiderMediaProxy() {
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
	direct := ""
	if !thunder.Match(playURL) {
		// do=js|py 仍是脚本代理，只改写对外可达根。
		if localproxy.IsSpiderProxyURL(playURL) {
			return playproxy.PublicizeURL(playURL, headers), ""
		}
		if resolveM3U8 {
			if resolved, src, err := m3u8.ResolveForPlayback(playURL, headers, port); err == nil && resolved != "" {
				if src != "" && src != resolved {
					direct = src
				}
				playURL = resolved
			}
		}
		before := playURL
		playURL = playproxy.Register(playURL, headers)
		if direct == "" && playURL != before {
			direct = before
		}
	}
	return playproxy.PublicizeURL(playURL, headers), headerCapableDirect(direct)
}

// headerCapableDirect 留下播放器自己能请求的 http(s)。回环、本机代拉地址留空。
func headerCapableDirect(raw string) string {
	raw = strings.TrimSpace(raw)
	if raw == "" || playproxy.NeedsLocalRelay(raw) {
		return ""
	}
	u, err := url.Parse(raw)
	if err != nil || u.Host == "" {
		return ""
	}
	switch strings.ToLower(u.Scheme) {
	case "http", "https":
	default:
		return ""
	}
	host := strings.ToLower(u.Hostname())
	if host == "localhost" || host == "::1" {
		return ""
	}
	if ip := net.ParseIP(host); ip != nil && ip.IsLoopback() {
		return ""
	}
	if u.Path == "/proxy" || strings.HasPrefix(u.Path, "/proxy/") {
		return ""
	}
	return raw
}

// exposeLocalFile 远端前端播放时，把本机文件改成 /file/ 地址。本机请求保持原路径。content: 不改。
func exposeLocalFile(raw string) string {
	raw = strings.TrimSpace(raw)
	if raw == "" || hostclient.PublicBase() == "" {
		return raw
	}
	if strings.HasPrefix(strings.ToLower(raw), "content:") {
		return raw
	}
	if !IsLocalMediaURL(raw) {
		return raw
	}
	resolved := paths.ResolveMediaPath(raw)
	if resolved == "" {
		return raw
	}
	rel := strings.TrimPrefix(filepath.ToSlash(resolved), "/")
	parts := strings.Split(rel, "/")
	enc := make([]string, 0, len(parts))
	for _, p := range parts {
		if p == "" {
			continue
		}
		enc = append(enc, url.PathEscape(p))
	}
	if len(enc) == 0 {
		return raw
	}
	return strings.TrimRight(hostclient.PublicBase(), "/") + "/file/" + strings.Join(enc, "/")
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
