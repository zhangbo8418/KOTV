package playproxy

import (
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/bobo/KOTV/internal/hostclient"
	"github.com/bobo/KOTV/internal/settings"
)

// 将带自定义 Header 的远端媒体转成本地可播地址，供 VLC/MPV 无 header 能力时使用。

type entry struct {
	URL       string
	Headers   map[string]string
	ExpiresAt time.Time
}

var (
	mu      sync.Mutex
	entries = map[string]entry{}
	portFn  func() int
	// rxBytes 代理从远端拉到的累计字节（供缓冲浮层测速，与播放器解耦）。
	rxBytes atomic.Uint64
)

// RxBytes 返回代理累计下行字节。
func RxBytes() uint64 { return rxBytes.Load() }

// SetPortFunc 注入本地服务端口读取函数。
func SetPortFunc(fn func() int) { portFn = fn }

// Register 注册一次带 header 的播放，返回本地代理 URL；无 header 时原样返回。
func Register(rawURL string, headers map[string]string) string {
	if rawURL == "" || len(headers) == 0 {
		return rawURL
	}
	// 已是本地代理则不再包一层。
	if strings.Contains(rawURL, "/proxy/play?") || strings.Contains(rawURL, "/proxy/cached_m3u8") {
		return rawURL
	}
	id := newID()
	cp := make(map[string]string, len(headers))
	for k, v := range headers {
		cp[k] = v
	}
	mu.Lock()
	entries[id] = entry{URL: rawURL, Headers: cp, ExpiresAt: time.Now().Add(6 * time.Hour)}
	mu.Unlock()
	return fmt.Sprintf("%s/proxy/play?id=%s", LocalHTTPBase(), id)
}

// LocalHTTPBase 本机默认 127.0.0.1:port；远端请求则用 hostclient.PublicBase。
func LocalHTTPBase() string {
	if b := hostclient.PublicBase(); b != "" {
		return b
	}
	port := 9978
	if portFn != nil {
		if p := portFn(); p > 0 {
			port = p
		}
	}
	return fmt.Sprintf("http://127.0.0.1:%d", port)
}

// PublicizeURL 将回环或内网地址换成当前请求的对外根（保留 path/query）。
// 远端经域名/反代访问时，避免把 127.0.0.1 或局域网 IP 原样交给客户端。
func PublicizeURL(raw string) string {
	raw = strings.TrimSpace(raw)
	base := hostclient.PublicBase()
	if raw == "" || base == "" {
		return raw
	}
	u, err := url.Parse(raw)
	if err != nil {
		return raw
	}
	host := strings.ToLower(u.Hostname())
	if host == "" {
		return raw
	}
	pb, err := url.Parse(base)
	if err != nil || pb.Host == "" {
		return raw
	}
	pubHost := strings.ToLower(pb.Hostname())
	if host == pubHost {
		// 已是对外主机，仅统一 scheme（https 反代）。
		if pb.Scheme != "" && u.Scheme != pb.Scheme {
			u.Scheme = pb.Scheme
			u.Host = pb.Host
			return u.String()
		}
		return raw
	}
	if !isRewriteableProxyHost(host) {
		return raw
	}
	u.Scheme = pb.Scheme
	u.Host = pb.Host
	return u.String()
}

func isRewriteableProxyHost(host string) bool {
	host = strings.ToLower(strings.TrimSpace(host))
	if host == "" || host == "127.0.0.1" || host == "localhost" || host == "::1" {
		return true
	}
	ip := net.ParseIP(host)
	if ip == nil {
		return false
	}
	return ip.IsLoopback() || ip.IsPrivate() || ip.IsLinkLocalUnicast()
}

func newID() string {
	var b [8]byte
	_, _ = rand.Read(b[:])
	return hex.EncodeToString(b[:])
}

func lookup(id string) (entry, bool) {
	mu.Lock()
	defer mu.Unlock()
	e, ok := entries[id]
	if !ok {
		return entry{}, false
	}
	if time.Now().After(e.ExpiresAt) {
		delete(entries, id)
		return entry{}, false
	}
	return e, true
}

// Resolve 若为本地 /proxy/play 地址，返回原始 URL 与登记 Headers；否则原样返回。
func Resolve(proxyOrRaw string) (rawURL string, headers map[string]string) {
	proxyOrRaw = strings.TrimSpace(proxyOrRaw)
	if proxyOrRaw == "" {
		return "", nil
	}
	if !strings.Contains(proxyOrRaw, "/proxy/play?") {
		return proxyOrRaw, nil
	}
	id := ""
	if i := strings.Index(proxyOrRaw, "id="); i >= 0 {
		id = proxyOrRaw[i+3:]
		if j := strings.IndexAny(id, "&?#"); j >= 0 {
			id = id[:j]
		}
	}
	if id == "" {
		return proxyOrRaw, nil
	}
	e, ok := lookup(id)
	if !ok || e.URL == "" {
		return proxyOrRaw, nil
	}
	cp := make(map[string]string, len(e.Headers))
	for k, v := range e.Headers {
		cp[k] = v
	}
	return e.URL, cp
}

// Handle 代理拉流并转发 Range，注入登记的请求头。
func Handle(w http.ResponseWriter, r *http.Request) {
	id := r.URL.Query().Get("id")
	e, ok := lookup(id)
	if !ok || e.URL == "" {
		http.Error(w, "not found", http.StatusNotFound)
		return
	}
	rangeHdr := ""
	if !isPlaylistURL(e.URL) {
		if rng := r.Header.Get("Range"); rng != "" && !isFullFileRange(rng) {
			rangeHdr = rng
		}
	}
	resp, err := e.fetch(r, rangeHdr)
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadGateway)
		return
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
}

func (e entry) fetch(r *http.Request, rangeHdr string) (*http.Response, error) {
	req, err := http.NewRequestWithContext(r.Context(), http.MethodGet, e.URL, nil)
	if err != nil {
		return nil, err
	}
	applyUpstreamHeaders(req, e.Headers)
	if rangeHdr != "" {
		req.Header.Set("Range", rangeHdr)
	}
	if req.Header.Get("User-Agent") == "" {
		req.Header.Set("User-Agent", settings.PlayUA())
	}
	client := &http.Client{
		// 网盘 CDN 常 302 到另一域名；默认 Client 跨域会剥 Cookie → 403 HTML →
		// 播放器报 invalid or unsupported media。
		CheckRedirect: func(next *http.Request, via []*http.Request) error {
			if len(via) >= 10 {
				return fmt.Errorf("stopped after 10 redirects")
			}
			applyUpstreamHeaders(next, e.Headers)
			if rangeHdr != "" && !isPlaylistURL(e.URL) {
				next.Header.Set("Range", rangeHdr)
			}
			if next.Header.Get("User-Agent") == "" {
				next.Header.Set("User-Agent", settings.PlayUA())
			}
			return nil
		},
	}
	return client.Do(req)
}

func applyUpstreamHeaders(req *http.Request, headers map[string]string) {
	for k, v := range headers {
		if strings.TrimSpace(k) == "" || strings.TrimSpace(v) == "" {
			continue
		}
		lk := strings.ToLower(k)
		switch lk {
		case "host", "content-length", "content-type", "connection", "transfer-encoding":
			continue
		}
		req.Header.Set(k, v)
	}
}

type countingWriter struct {
	w io.Writer
}

func (c countingWriter) Write(p []byte) (int, error) {
	n, err := c.w.Write(p)
	if n > 0 {
		rxBytes.Add(uint64(n))
	}
	return n, err
}

func isPlaylistURL(raw string) bool {
	low := strings.ToLower(raw)
	return strings.Contains(low, ".m3u8") || strings.Contains(low, "mpegurl")
}

func isFullFileRange(rng string) bool {
	switch strings.TrimSpace(strings.ToLower(rng)) {
	case "bytes=0-", "bytes=0":
		return true
	default:
		return false
	}
}

type writeOnly struct{ http.ResponseWriter }

func (w writeOnly) Write(p []byte) (int, error) { return w.ResponseWriter.Write(p) }
