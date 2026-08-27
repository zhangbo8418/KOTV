package playproxy

import (
	"io"
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
	rangeHdr := ""
	if rng := r.Header.Get("Range"); rng != "" && !isFullFileRange(rng) {
		rangeHdr = rng
	}
	if rangeHdr == "" {
		if v := strings.TrimSpace(r.URL.Query().Get("range")); v != "" && !isFullFileRange(v) {
			rangeHdr = v
		}
	}
	e := entry{URL: media, Headers: headers}
	resp, err := e.fetch(r, rangeHdr)
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadGateway)
		return true
	}
	defer resp.Body.Close()
	for _, h := range []string{"Content-Type", "Content-Length", "Accept-Ranges", "Content-Range"} {
		if v := resp.Header.Get(h); v != "" {
			w.Header().Set(h, v)
		}
	}
	w.Header().Set("Access-Control-Allow-Origin", "*")
	w.WriteHeader(resp.StatusCode)
	_, _ = io.Copy(countingWriter{w: writeOnly{w}}, resp.Body)
	return true
}
