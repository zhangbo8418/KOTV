package hlsproxy

import (
	"net/url"
	"regexp"
	"strings"
)

var uriAttrRe = regexp.MustCompile(`URI="([^"]+)"`)

// rewritePlaylist 把 playlist 内 URI 映射到本地代理地址。
func rewritePlaylist(text, playlistURL string, mapURI func(abs string) string) string {
	lines := strings.Split(text, "\n")
	var out strings.Builder
	out.Grow(len(text) + 256)
	for i, raw := range lines {
		line := strings.TrimRight(raw, "\r")
		trim := strings.TrimSpace(line)
		switch {
		case strings.HasPrefix(trim, "#") && strings.Contains(trim, `URI="`):
			out.WriteString(rewriteURIAttributes(raw, playlistURL, mapURI))
		case trim != "" && !strings.HasPrefix(trim, "#"):
			out.WriteString(mapURI(resolveURL(playlistURL, trim)))
		default:
			out.WriteString(raw)
		}
		if i < len(lines)-1 {
			out.WriteByte('\n')
		}
	}
	return out.String()
}

func rewriteURIAttributes(line, playlistURL string, mapURI func(abs string) string) string {
	return uriAttrRe.ReplaceAllStringFunc(line, func(m string) string {
		sub := uriAttrRe.FindStringSubmatch(m)
		if len(sub) < 2 {
			return m
		}
		raw := sub[1]
		if raw == "" || strings.HasPrefix(raw, "data:") {
			return m
		}
		return `URI="` + mapURI(resolveURL(playlistURL, raw)) + `"`
	})
}

func resolveURL(base, ref string) string {
	ref = strings.TrimSpace(ref)
	if ref == "" {
		return ref
	}
	if strings.HasPrefix(ref, "http://") || strings.HasPrefix(ref, "https://") {
		return ref
	}
	bu, err := url.Parse(base)
	if err != nil {
		return ref
	}
	ru, err := url.Parse(ref)
	if err != nil {
		return ref
	}
	return bu.ResolveReference(ru).String()
}

func looksLikePlaylist(text string) bool {
	t := strings.TrimSpace(text)
	return strings.HasPrefix(t, "#EXTM3U") || strings.Contains(t, "\n#EXTM3U")
}

func isPlaylistPath(raw string) bool {
	low := strings.ToLower(raw)
	if i := strings.IndexByte(low, '?'); i >= 0 {
		low = low[:i]
	}
	return strings.HasSuffix(low, ".m3u8") || strings.HasSuffix(low, ".m3u")
}

func isPlaylistContentType(ct string) bool {
	low := strings.ToLower(ct)
	return strings.Contains(low, "mpegurl") || strings.Contains(low, "m3u8")
}

func mediaMIME(u, contentType string) string {
	if ct := strings.TrimSpace(contentType); ct != "" {
		return ct
	}
	low := strings.ToLower(u)
	if i := strings.IndexByte(low, '?'); i >= 0 {
		low = low[:i]
	}
	switch {
	case strings.HasSuffix(low, ".ts"), strings.HasSuffix(low, ".m2ts"):
		return "video/MP2T"
	case strings.HasSuffix(low, ".mp4"), strings.HasSuffix(low, ".m4s"), strings.HasSuffix(low, ".m4v"):
		return "video/mp4"
	case strings.HasSuffix(low, ".aac"):
		return "audio/aac"
	case strings.HasSuffix(low, ".mp3"):
		return "audio/mpeg"
	case strings.HasSuffix(low, ".m4a"):
		return "audio/mp4"
	default:
		return "application/octet-stream"
	}
}
