package playproxy

import (
	"net/http"
	"strings"
)

// TryHandleEmbeddedProxy 若请求是「url+header 编进 query」的网盘代理，则由 Go 真流式转发。
// 成功处理返回 true（已写响应）；否则 false，交给 jar bridge。
//
// 避免 Java spill 整段原画：远端 PC → 安卓 /proxy?do=quark&url=&header= 时必走这里。
func TryHandleEmbeddedProxy(w http.ResponseWriter, r *http.Request) bool {
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
	serveEntry(w, r, entry{URL: media, Headers: headers}, rangeHdr)
	return true
}
