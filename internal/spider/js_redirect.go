package spider

import (
	"bytes"
	"compress/flate"
	"compress/gzip"
	"compress/zlib"
	"io"
	"net/http"
	"net/url"
	"strings"
	"sync"

	"github.com/bobo/KOTV/internal/util"
)

// jsRedirectMap ResponseInterceptor.redirectMap：
// key = 302 Location（绝对 URL），value = 发起 302 的原始请求 URL。
var jsRedirectMap sync.Map

func rememberJSRedirect(from, location string) {
	from = strings.TrimSpace(from)
	location = strings.TrimSpace(location)
	if from == "" || location == "" {
		return
	}
	abs := resolveJSRedirectURL(from, location)
	if abs == "" {
		return
	}
	jsRedirectMap.Store(abs, from)
}

func resolveJSRedirectURL(base, location string) string {
	if strings.HasPrefix(location, "http://") || strings.HasPrefix(location, "https://") {
		return location
	}
	bu, err := url.Parse(base)
	if err != nil {
		return location
	}
	ref, err := url.Parse(location)
	if err != nil {
		return location
	}
	return bu.ResolveReference(ref).String()
}

func lookupJSRedirectOrigin(requestURL string) (string, bool) {
	if v, ok := jsRedirectMap.Load(strings.TrimSpace(requestURL)); ok {
		if s, ok := v.(string); ok && s != "" {
			return s, true
		}
	}
	return "", false
}

func trackJSRedirects(req *http.Request, via []*http.Request) error {
	if len(via) >= 10 {
		return http.ErrUseLastResponse
	}
	if len(via) > 0 && req != nil {
		prev := via[len(via)-1]
		if prev != nil && prev.URL != nil && req.URL != nil {
			rememberJSRedirect(prev.URL.String(), req.URL.String())
		}
	}
	return nil
}

func applyJSRedirectDance(reqURL string, resp *http.Response, body []byte) (code int, hdrs http.Header, out []byte) {
	code = resp.StatusCode
	hdrs = resp.Header.Clone()
	out = body
	if isHTTPRedirect(code) {
		if loc := resp.Header.Get("Location"); loc != "" {
			rememberJSRedirect(reqURL, loc)
		}
		return code, hdrs, out
	}
	if code == 406 {
		if origin, ok := lookupJSRedirectOrigin(reqURL); ok {
			h := make(http.Header)
			h.Set("Location", origin)
			return http.StatusFound, h, nil
		}
	}
	return code, hdrs, out
}

func isHTTPRedirect(code int) bool {
	switch code {
	case 301, 302, 303, 307, 308:
		return true
	default:
		return false
	}
}

func drainBody(resp *http.Response) []byte {
	if resp == nil || resp.Body == nil {
		return nil
	}
	b, _ := io.ReadAll(resp.Body)
	return b
}

// jsRequestTransport 关闭自动解压，以便对 raw deflate 的处理。
func jsRequestTransport() http.RoundTripper {
	base := util.GetClient().Transport
	if base == nil {
		base = http.DefaultTransport
	}
	if t, ok := base.(*http.Transport); ok {
		cl := t.Clone()
		cl.DisableCompression = true
		return cl
	}
	return &http.Transport{DisableCompression: true}
}

// decodeJSContentEncoding ResponseInterceptor：gzip + Inflater(nowrap) deflate。
func decodeJSContentEncoding(encoding string, body []byte) []byte {
	if len(body) == 0 {
		return body
	}
	switch strings.ToLower(strings.TrimSpace(encoding)) {
	case "gzip":
		r, err := gzip.NewReader(bytes.NewReader(body))
		if err != nil {
			return body
		}
		defer r.Close()
		if out, err := io.ReadAll(r); err == nil {
			return out
		}
	case "deflate":
		// TV：new Inflater(true) → raw deflate（无 zlib 头）
		if out, err := inflateRaw(body); err == nil {
			return out
		}
		// 兼容 zlib-wrapped deflate
		if r, err := zlib.NewReader(bytes.NewReader(body)); err == nil {
			out, err2 := io.ReadAll(r)
			r.Close()
			if err2 == nil {
				return out
			}
		}
	}
	return body
}

func inflateRaw(body []byte) ([]byte, error) {
	r := flate.NewReader(bytes.NewReader(body))
	defer r.Close()
	return io.ReadAll(r)
}
