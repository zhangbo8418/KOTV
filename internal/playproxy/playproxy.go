package playproxy

import (
	"bytes"
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"regexp"
	"strconv"
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
	return register(rawURL, headers)
}

// NeedsLocalRelay 回环地址是否标了非引擎端口。这种端口只在跑引擎的机器上听得到。
func NeedsLocalRelay(rawURL string) bool {
	u, err := url.Parse(strings.TrimSpace(rawURL))
	if err != nil || u.Host == "" || !isLoopbackHost(u.Hostname()) {
		return false
	}
	p := u.Port()
	if p == "" {
		return false
	}
	return p != strconv.Itoa(enginePort())
}

func enginePort() int {
	if portFn != nil {
		if p := portFn(); p > 0 {
			return p
		}
	}
	return 9978
}

func register(rawURL string, headers map[string]string) string {
	if rawURL == "" {
		return ""
	}
	if strings.Contains(rawURL, "/proxy/play?") || strings.Contains(rawURL, "/proxy/cached_m3u8") {
		return rawURL
	}
	id := newID()
	cp := make(map[string]string, len(headers))
	for k, v := range headers {
		if strings.TrimSpace(k) == "" || strings.TrimSpace(v) == "" {
			continue
		}
		cp[k] = v
	}
	mu.Lock()
	entries[id] = entry{URL: rawURL, Headers: cp, ExpiresAt: time.Now().Add(6 * time.Hour)}
	mu.Unlock()
	return fmt.Sprintf("%s/proxy/play?id=%s", LocalHTTPBase(), id)
}

func isLoopbackHost(host string) bool {
	host = strings.ToLower(strings.TrimSpace(host))
	if host == "127.0.0.1" || host == "localhost" || host == "::1" {
		return true
	}
	ip := net.ParseIP(host)
	return ip != nil && ip.IsLoopback()
}

// LocalHTTPBase 本机默认 127.0.0.1:port；远端请求则用 hostclient.PublicBase。
func LocalHTTPBase() string {
	if b := hostclient.PublicBase(); b != "" {
		return b
	}
	return fmt.Sprintf("http://127.0.0.1:%d", enginePort())
}

// PublicizeURL 把地址改成当前请求的客户端打得开的形式。
// 回环且端口不是本引擎时，由本机代拉后给出已有的 /proxy/play。
// 本引擎路径上的回环或内网主机换成前端填写的连接根。其它地址保持不变。
// 本机请求（PublicBase 为空）原样返回。headers 可选，只在代拉时附上。
func PublicizeURL(raw string, headers ...map[string]string) string {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return ""
	}
	if hostclient.PublicBase() != "" && NeedsLocalRelay(raw) {
		var hdr map[string]string
		if len(headers) > 0 {
			hdr = headers[0]
		}
		raw = register(raw, hdr)
	}
	return rewritePublicHost(raw)
}

func rewritePublicHost(raw string) string {
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
		if adoptPublicOrigin(u, pb) {
			u.Scheme = pb.Scheme
			u.Host = pb.Host
			return u.String()
		}
		return raw
	}
	if !isRewriteableProxyHost(host) || !isEngineServedPath(u.Path) {
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

// adoptPublicOrigin 引擎自己的路径改成前端这次连接用的 scheme 和端口。
func adoptPublicOrigin(u, pb *url.URL) bool {
	if u == nil || pb == nil || pb.Scheme == "" || !isEngineServedPath(u.Path) {
		return false
	}
	if u.Scheme != pb.Scheme {
		return true
	}
	return u.Host != pb.Host
}

func isEngineServedPath(path string) bool {
	path = strings.TrimSuffix(path, "/")
	switch {
	case path == "/proxy" || strings.HasPrefix(path, "/proxy/"):
		return true
	case path == "/file" || strings.HasPrefix(path, "/file/"):
		return true
	case strings.HasPrefix(path, "/image/"):
		return true
	case path == "/parse" || strings.HasPrefix(path, "/parse/"):
		return true
	case path == "/tvbus" || path == "/cache" || strings.HasPrefix(path, "/cache/"):
		return true
	case path == "/upload" || strings.HasPrefix(path, "/upload/"):
		return true
	case path == "/health" || path == "/media" || path == "/device":
		return true
	case path == "/action" || path == "/postMsg" || path == "/uiReply":
		return true
	case path == "/newFolder" || path == "/delFolder" || path == "/delFile":
		return true
	case strings.HasPrefix(path, "/api/"):
		return true
	default:
		return false
	}
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
	rangeHdr := strings.TrimSpace(r.Header.Get("Range"))
	serveEntry(w, r, e, rangeHdr)
}

func serveEntry(w http.ResponseWriter, r *http.Request, e entry, rangeHdr string) {
	resp, err := e.fetch(r, rangeHdr)
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadGateway)
		return
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 400 {
		writePassthrough(w, resp, resp.Body)
		return
	}
	prefix := make([]byte, len("#EXTM3U"))
	n, _ := io.ReadFull(resp.Body, prefix)
	head := prefix[:n]
	if n == len(prefix) && bytes.Equal(head, []byte("#EXTM3U")) {
		rest, err := io.ReadAll(io.LimitReader(resp.Body, 8<<20))
		if err != nil {
			http.Error(w, err.Error(), http.StatusBadGateway)
			return
		}
		raw := make([]byte, 0, n+len(rest))
		raw = append(raw, head...)
		raw = append(raw, rest...)
		if out, ok := rewritePlaylist(string(raw), e.URL, e.Headers); ok {
			writeRewrittenPlaylist(w, resp, []byte(out))
			return
		}
		writePassthrough(w, resp, bytes.NewReader(raw))
		return
	}
	writePassthrough(w, resp, io.MultiReader(bytes.NewReader(head), resp.Body))
}

func writePassthrough(w http.ResponseWriter, resp *http.Response, body io.Reader) {
	copyResponseHeaders(w, resp.Header)
	w.WriteHeader(resp.StatusCode)
	dst := io.Writer(w)
	if f, ok := w.(http.Flusher); ok {
		dst = flushWriter{w: w, f: f}
	}
	_, _ = io.Copy(countingWriter{w: dst}, body)
}

func writeRewrittenPlaylist(w http.ResponseWriter, resp *http.Response, out []byte) {
	copyResponseHeaders(w, resp.Header)
	w.Header().Set("Content-Length", strconv.Itoa(len(out)))
	w.Header().Del("Content-Range")
	if w.Header().Get("Content-Type") == "" {
		w.Header().Set("Content-Type", "application/vnd.apple.mpegurl")
	}
	w.WriteHeader(resp.StatusCode)
	dst := io.Writer(w)
	if f, ok := w.(http.Flusher); ok {
		dst = flushWriter{w: w, f: f}
	}
	_, _ = countingWriter{w: dst}.Write(out)
}

// copyResponseHeaders 原样转发响应头。去掉逐跳头，不补 Accept-Ranges。
func copyResponseHeaders(w http.ResponseWriter, h http.Header) {
	hop := map[string]struct{}{
		"connection":          {},
		"keep-alive":          {},
		"proxy-authenticate":  {},
		"proxy-authorization": {},
		"te":                  {},
		"trailer":             {},
		"transfer-encoding":   {},
		"upgrade":             {},
	}
	for _, c := range h.Values("Connection") {
		for _, token := range strings.Split(c, ",") {
			if t := strings.ToLower(strings.TrimSpace(token)); t != "" {
				hop[t] = struct{}{}
			}
		}
	}
	for k, vals := range h {
		if _, skip := hop[strings.ToLower(k)]; skip {
			continue
		}
		for _, v := range vals {
			w.Header().Add(k, v)
		}
	}
	w.Header().Set("Access-Control-Allow-Origin", "*")
}

type flushWriter struct {
	w io.Writer
	f http.Flusher
}

func (fw flushWriter) Write(p []byte) (int, error) {
	n, err := fw.w.Write(p)
	if n > 0 && fw.f != nil {
		fw.f.Flush()
	}
	return n, err
}

var playlistTagURIRe = regexp.MustCompile(`(?i)\bURI="([^"]+)"`)

func rewritePlaylist(content, base string, headers map[string]string) (string, bool) {
	changed := false
	lines := strings.Split(content, "\n")
	for i, line := range lines {
		trim := strings.TrimSpace(strings.TrimRight(line, "\r"))
		if trim == "" || strings.HasPrefix(trim, "#") {
			continue
		}
		abs := resolveRef(base, trim)
		next := proxyIfRemote(abs, headers)
		if next != abs {
			lines[i] = next
			changed = true
		}
	}
	out := strings.Join(lines, "\n")
	if strings.Contains(strings.ToUpper(out), "URI=") {
		out = playlistTagURIRe.ReplaceAllStringFunc(out, func(m string) string {
			sub := playlistTagURIRe.FindStringSubmatch(m)
			if len(sub) < 2 {
				return m
			}
			raw := sub[1]
			if raw == "" || strings.HasPrefix(raw, "data:") {
				return m
			}
			abs := resolveRef(base, raw)
			next := proxyIfRemote(abs, headers)
			if next == abs {
				return m
			}
			changed = true
			return `URI="` + next + `"`
		})
	}
	if !changed {
		return content, false
	}
	return out, true
}

func proxyIfRemote(abs string, headers map[string]string) string {
	if !NeedsLocalRelay(abs) {
		return abs
	}
	if strings.Contains(abs, "/proxy/play?") || strings.Contains(abs, "/proxy/cached_m3u8") {
		return abs
	}
	return register(abs, headers)
}

func resolveRef(base, ref string) string {
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

func (e entry) fetch(r *http.Request, rangeHdr string) (*http.Response, error) {
	req, err := http.NewRequestWithContext(r.Context(), http.MethodGet, e.URL, nil)
	if err != nil {
		return nil, err
	}
	applyUpstreamHeaders(req, e.Headers)
	if rangeHdr != "" {
		req.Header.Set("Range", rangeHdr)
	}
	if req.Header.Get("User-Agent") == "" && !isLoopbackHost(req.URL.Hostname()) {
		req.Header.Set("User-Agent", settings.PlayUA())
	}
	client := &http.Client{
		// 不设 Timeout：整片可能很长。关闭自动解压，避免声明 gzip 后把 Content-Length 拿掉。
		Transport: playTransport,
		// 网盘 CDN 常 302 到另一域名；默认 Client 跨域会剥 Cookie → 403 HTML →
		// 播放器报 invalid or unsupported media。
		CheckRedirect: func(next *http.Request, via []*http.Request) error {
			if len(via) >= 10 {
				return fmt.Errorf("stopped after 10 redirects")
			}
			applyUpstreamHeaders(next, e.Headers)
			if rangeHdr != "" {
				next.Header.Set("Range", rangeHdr)
			}
			if next.Header.Get("User-Agent") == "" && !isLoopbackHost(next.URL.Hostname()) {
				next.Header.Set("User-Agent", settings.PlayUA())
			}
			return nil
		},
	}
	return client.Do(req)
}

var playTransport = newPlayTransport()

func newPlayTransport() http.RoundTripper {
	base, ok := http.DefaultTransport.(*http.Transport)
	if !ok {
		return &http.Transport{DisableCompression: true}
	}
	tr := base.Clone()
	tr.DisableCompression = true
	return tr
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
