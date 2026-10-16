package spider

import (
	"context"
	"crypto/tls"
	"io"
	"net"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"

	"github.com/bobo/KOTV/internal/util"
)

// jsRedirectMap：302 Location（绝对 URL）→ 发起请求的原始 URL（JS 爬虫 insecure 客户端）。
const jsRedirectMax = 512

var (
	jsRedirectMu  sync.Mutex
	jsRedirectMap = map[string]string{}
	jsRedirectOrd []string
)

// ClearJSRedirectMap 清空 JS 侧 302 回源映射（清理缓存工具）。
func ClearJSRedirectMap() {
	jsRedirectMu.Lock()
	defer jsRedirectMu.Unlock()
	jsRedirectMap = map[string]string{}
	jsRedirectOrd = nil
}

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
	jsRedirectMu.Lock()
	defer jsRedirectMu.Unlock()
	if _, ok := jsRedirectMap[abs]; !ok {
		jsRedirectOrd = append(jsRedirectOrd, abs)
	}
	jsRedirectMap[abs] = from
	for len(jsRedirectMap) > jsRedirectMax && len(jsRedirectOrd) > 0 {
		victim := jsRedirectOrd[0]
		jsRedirectOrd = jsRedirectOrd[1:]
		delete(jsRedirectMap, victim)
	}
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
	jsRedirectMu.Lock()
	defer jsRedirectMu.Unlock()
	s, ok := jsRedirectMap[strings.TrimSpace(requestURL)]
	if !ok || s == "" {
		return "", false
	}
	return s, true
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

// jsRequestTransport 关闭自动解压；TLS 不校验（OkHttp trust-all）；hosts 表改写 dial 主机名。
func jsRequestTransport() http.RoundTripper {
	base := util.GetClient().Transport
	if base == nil {
		base = http.DefaultTransport
	}
	var cl *http.Transport
	if t, ok := base.(*http.Transport); ok {
		cl = t.Clone()
	} else {
		cl = &http.Transport{}
	}
	cl.DisableCompression = true
	if cl.TLSClientConfig == nil {
		cl.TLSClientConfig = &tls.Config{InsecureSkipVerify: true} //nolint:gosec
	} else {
		cl.TLSClientConfig = cl.TLSClientConfig.Clone()
		cl.TLSClientConfig.InsecureSkipVerify = true
	}
	baseDial := cl.DialContext
	if baseDial == nil {
		d := &net.Dialer{Timeout: 30 * time.Second}
		baseDial = d.DialContext
	}
	cl.DialContext = func(ctx context.Context, network, addr string) (net.Conn, error) {
		host, port, err := net.SplitHostPort(addr)
		if err != nil {
			host = addr
			port = ""
		}
		mapped := ResolveVodHost(host)
		if mapped != host && mapped != "" {
			if port != "" {
				addr = net.JoinHostPort(mapped, port)
			} else {
				addr = mapped
			}
		}
		return baseDial(ctx, network, addr)
	}
	return cl
}

func wrapDialTimeout(base func(context.Context, string, string) (net.Conn, error), d time.Duration) func(context.Context, string, string) (net.Conn, error) {
	if d <= 0 {
		return base
	}
	if base == nil {
		dialer := &net.Dialer{Timeout: d}
		base = dialer.DialContext
	}
	return func(ctx context.Context, network, addr string) (net.Conn, error) {
		cctx, cancel := context.WithTimeout(ctx, d)
		defer cancel()
		return base(cctx, network, addr)
	}
}

// decodeJSContentEncoding：gzip，以及 nowrap deflate。
func decodeJSContentEncoding(encoding string, body []byte) []byte {
	return util.DecodeContentEncoding(encoding, body)
}
