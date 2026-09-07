package localproxy

import (
	"fmt"
	"net/url"
	"path/filepath"
	"strings"

	"github.com/bobo/KOTV/internal/util"
)

// ConvertScheme assets / proxy / file → 本机 HTTP。
func ConvertScheme(value string) string {
	value = strings.TrimSpace(value)
	if value == "" {
		return value
	}
	localBase := fmt.Sprintf("http://127.0.0.1:%d", Port())
	switch {
	case strings.HasPrefix(value, "assets://"):
		return localBase + "/" + strings.TrimPrefix(value, "assets://")
	case strings.HasPrefix(value, "proxy://"):
		return localBase + "/proxy?" + strings.TrimPrefix(value, "proxy://")
	case strings.HasPrefix(value, "file://"), strings.HasPrefix(value, "file:/"):
		pathPart := value
		if local, ok := util.FileURLPath(value); ok {
			pathPart = filepath.ToSlash(local)
		} else {
			pathPart = strings.TrimPrefix(pathPart, "file://")
			pathPart = strings.TrimPrefix(pathPart, "file:/")
			if u, err := url.PathUnescape(pathPart); err == nil {
				pathPart = u
			}
		}
		esc := url.PathEscape(pathPart)
		esc = strings.ReplaceAll(esc, "%2F", "/")
		return localBase + "/file/" + esc
	default:
		return value
	}
}

// IsSpiderProxyURL 是否为爬虫本地代理（/proxy?...），不含 /proxy/play、cached_m3u8、bt。
func IsSpiderProxyURL(raw string) bool {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return false
	}
	low := strings.ToLower(raw)
	if strings.Contains(low, "/proxy/play") ||
		strings.Contains(low, "/proxy/cached_m3u8") ||
		strings.Contains(low, "/proxy/bt/") {
		return false
	}
	if strings.HasPrefix(low, "proxy://") {
		return true
	}
	u, err := url.Parse(raw)
	if err != nil {
		return false
	}
	path := strings.TrimSuffix(u.Path, "/")
	return path == "/proxy"
}
