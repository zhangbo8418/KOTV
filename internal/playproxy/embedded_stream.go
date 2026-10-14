package playproxy

import (
	"net/http"
	"strings"
)

// TryHandleEmbeddedProxy 远端请求且为「url+header 编进 query」的网盘代理时，
// 由 Go Range 转发。本机不拦，交给 jar（与播放器直打 /proxy 同路径）。
// 成功处理返回 true；否则 false。
func TryHandleEmbeddedProxy(w http.ResponseWriter, r *http.Request) bool {
	if !ShouldExpandSpiderMediaProxy() {
		return false
	}
	raw := ""
	if r.URL != nil {
		if strings.HasPrefix(r.URL.Path, "/proxy") {
			raw = "http://127.0.0.1" + r.URL.RequestURI()
		}
	}
	if raw == "" {
		return false
	}
	media, headers, ok := ExpandSpiderMediaProxy(raw, nil)
	if !ok {
		return false
	}
	rangeHdr := strings.TrimSpace(r.Header.Get("Range"))
	if rangeHdr == "" {
		rangeHdr = strings.TrimSpace(r.URL.Query().Get("range"))
	}
	serveEntry(w, r, entry{URL: media, Headers: headers}, rangeHdr, "")
	return true
}
