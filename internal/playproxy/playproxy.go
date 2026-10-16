package playproxy

import (
	"bufio"
	"bytes"
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
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
	"github.com/bobo/KOTV/internal/localproxy"
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
	return localproxy.DefaultPort
}

func register(rawURL string, headers map[string]string) string {
	if rawURL == "" {
		return ""
	}
	if strings.Contains(rawURL, "/proxy/play?") || strings.Contains(rawURL, "/proxy/cached_m3u8") || strings.Contains(rawURL, "/proxy/rolling_m3u8") {
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
	now := time.Now()
	mu.Lock()
	for k, e := range entries {
		if now.After(e.ExpiresAt) {
			delete(entries, k)
		}
	}
	trimEntriesHalfLocked(entriesMax)
	entries[id] = entry{URL: rawURL, Headers: cp, ExpiresAt: now.Add(6 * time.Hour)}
	mu.Unlock()
	return fmt.Sprintf("%s/proxy/play?id=%s", LocalHTTPBase(), id)
}

const entriesMax = 256

// trimEntriesHalfLocked 超上限时删一半，并 kill 对应 splice（调用方已持 mu）。
func trimEntriesHalfLocked(max int) {
	if len(entries) < max {
		return
	}
	n := len(entries) / 2
	killed := make([]string, 0, n)
	for k := range entries {
		if n <= 0 {
			break
		}
		delete(entries, k)
		killed = append(killed, k)
		n--
	}
	for _, id := range killed {
		killSpliceByKey(id)
	}
}

// Clear 清空播放代理登记表与活跃 splice 槽（清理缓存工具）。
func Clear() {
	spliceMu.Lock()
	holds := make([]*spliceHold, 0, len(spliceLive))
	for _, h := range spliceLive {
		holds = append(holds, h)
	}
	spliceLive = map[string]*spliceHold{}
	spliceMu.Unlock()
	for _, h := range holds {
		if h != nil {
			h.kill()
		}
	}
	mu.Lock()
	entries = map[string]entry{}
	mu.Unlock()
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
	if p := enginePort(); p > 0 && p != localproxy.DefaultPort {
		return fmt.Sprintf("http://127.0.0.1:%d", p)
	}
	return localproxy.LocalBaseURL()
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
	serveEntry(w, r, e, rangeHdr, id)
}

// 播放器发下一次 Range 时，上一次连到爬虫的 TCP 往往还没关。
// 先关掉上一次，再拨这一次，爬虫才能继续送数据。
var (
	spliceMu   sync.Mutex
	spliceLive = map[string]*spliceHold{}
)

type spliceHold struct {
	key    string
	ctx    context.Context
	cancel context.CancelFunc

	mu   sync.Mutex
	conn net.Conn
	dead bool
}

func beginSplice(key string) *spliceHold {
	ctx, cancel := context.WithCancel(context.Background())
	slot := &spliceHold{key: key, ctx: ctx, cancel: cancel}
	spliceMu.Lock()
	prev := spliceLive[key]
	spliceLive[key] = slot
	spliceMu.Unlock()
	if prev != nil {
		prev.kill()
	}
	return slot
}

// killSpliceByKey 半裁登记表时结束对应活跃 splice。
func killSpliceByKey(key string) {
	if key == "" {
		return
	}
	spliceMu.Lock()
	h := spliceLive[key]
	if h != nil {
		delete(spliceLive, key)
	}
	spliceMu.Unlock()
	if h != nil {
		h.kill()
	}
}

func (s *spliceHold) kill() {
	s.mu.Lock()
	s.dead = true
	cancel := s.cancel
	c := s.conn
	s.conn = nil
	s.mu.Unlock()
	if cancel != nil {
		cancel()
	}
	if c != nil {
		_ = c.Close()
	}
}

func (s *spliceHold) bind(c net.Conn) bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.dead {
		return false
	}
	s.conn = c
	return true
}

func (s *spliceHold) takeConn() net.Conn {
	s.mu.Lock()
	defer s.mu.Unlock()
	c := s.conn
	s.conn = nil
	return c
}

func (s *spliceHold) alive() bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return !s.dead
}

func (s *spliceHold) release() {
	s.kill()
	spliceMu.Lock()
	if spliceLive[s.key] == s {
		delete(spliceLive, s.key)
	}
	spliceMu.Unlock()
}

func serveEntry(w http.ResponseWriter, r *http.Request, e entry, rangeHdr, playID string) {
	// 回环播放口按原始 TCP 转发状态行、响应头和正文。
	// 本机播放器直连时走的就是这条连接，不再经 http.Client 重封装。
	if tryRawSplice(w, r, e, rangeHdr, playID) {
		return
	}
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
	if strings.Contains(abs, "/proxy/play?") || strings.Contains(abs, "/proxy/cached_m3u8") || strings.Contains(abs, "/proxy/rolling_m3u8") {
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

// errUseHTTPClient 表示这条地址要走 TLS 或跨出回环，改由 http.Client 处理。
var errUseHTTPClient = errors.New("use http client")

type rawHead struct {
	statusLine string
	statusCode int
	header     http.Header
}

func tryRawSplice(w http.ResponseWriter, r *http.Request, e entry, rangeHdr, playID string) bool {
	if !canRawSplice(e.URL) {
		return false
	}
	if _, ok := w.(http.Hijacker); !ok {
		return false
	}
	key := playID
	if key == "" {
		key = e.URL
	}
	slot := beginSplice(key)
	defer slot.release()
	br, head, peek, finalURL, err := openRawUpstream(slot, e, rangeHdr, clientSpliceUA(r, e.Headers), r.Header.Get("If-Range"), r.Header.Get("Connection"), r.Header.Get("Accept-Encoding"))
	if errors.Is(err, errUseHTTPClient) {
		return false
	}
	if err != nil {
		if !slot.alive() {
			return true
		}
		http.Error(w, "连接本机播放端口失败", http.StatusBadGateway)
		return true
	}
	if bytes.Equal(peek, []byte("#EXTM3U")) {
		raw, rerr := readPlaylist(br, peek, head.header)
		if rerr != nil {
			http.Error(w, "读取播放列表失败", http.StatusBadGateway)
			return true
		}
		base := e.URL
		if finalURL != "" {
			base = finalURL
		}
		resp := &http.Response{StatusCode: head.statusCode, Header: head.header}
		if out, ok := rewritePlaylist(string(raw), base, e.Headers); ok {
			writeRewrittenPlaylist(w, resp, []byte(out))
			return true
		}
		writePassthrough(w, resp, bytes.NewReader(raw))
		return true
	}
	spliceToClient(w, slot, br, head, peek)
	return true
}

func canRawSplice(raw string) bool {
	u, err := url.Parse(strings.TrimSpace(raw))
	if err != nil || u.Scheme != "http" || u.Host == "" {
		return false
	}
	return NeedsLocalRelay(raw)
}

func clientSpliceUA(r *http.Request, headers map[string]string) string {
	if r == nil {
		return ""
	}
	for k := range headers {
		if strings.EqualFold(k, "user-agent") && strings.TrimSpace(headers[k]) != "" {
			return ""
		}
	}
	return r.Header.Get("User-Agent")
}

func openRawUpstream(slot *spliceHold, e entry, rangeHdr, ua, ifRange, connectionHdr, acceptEncoding string) (*bufio.Reader, rawHead, []byte, string, error) {
	current := e.URL
	for hop := 0; hop < 10; hop++ {
		if !slot.alive() {
			return nil, rawHead{}, nil, "", context.Canceled
		}
		u, err := url.Parse(current)
		if err != nil || u.Scheme != "http" || u.Host == "" {
			return nil, rawHead{}, nil, "", errUseHTTPClient
		}
		conn, err := (&net.Dialer{Timeout: 15 * time.Second}).DialContext(slot.ctx, "tcp", u.Host)
		if err != nil {
			return nil, rawHead{}, nil, "", err
		}
		tcpNoDelay(conn)
		if !slot.bind(conn) {
			conn.Close()
			return nil, rawHead{}, nil, "", context.Canceled
		}
		if werr := writeRawRequest(conn, u, e.Headers, rangeHdr, ua, ifRange, connectionHdr, acceptEncoding); werr != nil {
			_ = slot.takeConn()
			conn.Close()
			return nil, rawHead{}, nil, "", werr
		}
		_ = conn.SetReadDeadline(time.Now().Add(30 * time.Second))
		br := bufio.NewReaderSize(conn, 64*1024)
		head, err := readRawHead(br)
		if err != nil {
			_ = slot.takeConn()
			conn.Close()
			return nil, rawHead{}, nil, "", err
		}
		if head.statusCode >= 300 && head.statusCode < 400 {
			loc := strings.TrimSpace(head.header.Get("Location"))
			if c := slot.takeConn(); c != nil {
				c.Close()
			}
			if loc == "" {
				return nil, rawHead{}, nil, "", fmt.Errorf("重定向缺少 Location")
			}
			current = resolveRef(current, loc)
			continue
		}
		want := len("#EXTM3U")
		if cl, ok := contentLength(head.header); ok && cl < int64(want) {
			want = int(cl)
		}
		peek := make([]byte, want)
		n, rerr := io.ReadFull(br, peek)
		if rerr != nil && rerr != io.EOF && rerr != io.ErrUnexpectedEOF {
			if c := slot.takeConn(); c != nil {
				c.Close()
			}
			return nil, rawHead{}, nil, "", rerr
		}
		peek = peek[:n]
		if !bytes.Equal(peek, []byte("#EXTM3U")) {
			_ = conn.SetReadDeadline(time.Time{})
		}
		return br, head, peek, current, nil
	}
	return nil, rawHead{}, nil, "", fmt.Errorf("重定向次数过多")
}

func writeRawRequest(conn net.Conn, u *url.URL, headers map[string]string, rangeHdr, ua, ifRange, connectionHdr, acceptEncoding string) error {
	uri := u.RequestURI()
	if uri == "" {
		uri = "/"
	}
	var b strings.Builder
	fmt.Fprintf(&b, "GET %s HTTP/1.1\r\n", uri)
	fmt.Fprintf(&b, "Host: %s\r\n", u.Host)
	for k, v := range headers {
		if strings.TrimSpace(k) == "" || strings.TrimSpace(v) == "" {
			continue
		}
		if skipUpstreamHeader(k) {
			continue
		}
		fmt.Fprintf(&b, "%s: %s\r\n", http.CanonicalHeaderKey(k), v)
	}
	if rangeHdr == "" {
		rangeHdr = headerValue(headers, "range")
	}
	if rangeHdr != "" {
		fmt.Fprintf(&b, "Range: %s\r\n", rangeHdr)
	}
	if ua == "" {
		ua = headerValue(headers, "user-agent")
	}
	if ua != "" {
		fmt.Fprintf(&b, "User-Agent: %s\r\n", ua)
	}
	if ifRange == "" {
		ifRange = headerValue(headers, "if-range")
	}
	if ifRange != "" {
		fmt.Fprintf(&b, "If-Range: %s\r\n", ifRange)
	}
	// 播放器请求里的 Connection、Accept-Encoding 原样带上。没有就不写。
	if connectionHdr != "" {
		fmt.Fprintf(&b, "Connection: %s\r\n", connectionHdr)
	}
	if acceptEncoding != "" {
		fmt.Fprintf(&b, "Accept-Encoding: %s\r\n", acceptEncoding)
	}
	b.WriteString("\r\n")
	_, err := io.WriteString(conn, b.String())
	return err
}

func readRawHead(br *bufio.Reader) (rawHead, error) {
	var head rawHead
	var total int
	line, err := br.ReadString('\n')
	if err != nil {
		return head, err
	}
	total += len(line)
	head.statusLine = line
	if !strings.HasSuffix(head.statusLine, "\n") {
		head.statusLine += "\r\n"
	}
	fields := strings.Fields(strings.TrimSpace(line))
	if len(fields) < 2 {
		return head, fmt.Errorf("状态行无法识别")
	}
	head.statusCode, err = strconv.Atoi(fields[1])
	if err != nil {
		return head, err
	}
	head.header = make(http.Header)
	for {
		line, err = br.ReadString('\n')
		if err != nil {
			return head, err
		}
		total += len(line)
		if total > 1<<20 {
			return head, fmt.Errorf("响应头过大")
		}
		trim := strings.TrimRight(line, "\r\n")
		if trim == "" {
			return head, nil
		}
		k, v, ok := strings.Cut(trim, ":")
		if !ok {
			continue
		}
		head.header.Add(strings.TrimSpace(k), strings.TrimSpace(v))
	}
}

func spliceToClient(w http.ResponseWriter, slot *spliceHold, br *bufio.Reader, head rawHead, peek []byte) {
	hj := w.(http.Hijacker)
	client, _, err := hj.Hijack()
	if err != nil {
		slot.kill()
		http.Error(w, "连接本机播放端口失败", http.StatusBadGateway)
		return
	}
	tcpNoDelay(client)
	_ = client.SetDeadline(time.Time{})
	go func() {
		_, _ = io.Copy(io.Discard, client)
		slot.kill()
	}()
	defer client.Close()
	defer slot.kill()

	var buf bytes.Buffer
	buf.WriteString(head.statusLine)
	hdr := filterSpliceHeaders(head.header)
	hdr.Set("Access-Control-Allow-Origin", "*")
	_ = hdr.Write(&buf)
	buf.WriteString("\r\n")
	if _, err := client.Write(buf.Bytes()); err != nil {
		return
	}
	body := bufio.NewReader(io.MultiReader(bytes.NewReader(peek), br))
	copyBuf := make([]byte, 256*1024)
	_ = copyUpstreamBody(countingWriter{w: client}, body, head.header, copyBuf)
}

func readPlaylist(br *bufio.Reader, peek []byte, h http.Header) ([]byte, error) {
	const limit = 8 << 20
	if cl, ok := contentLength(h); ok {
		if int64(len(peek)) > cl {
			peek = peek[:cl]
		}
		need := cl - int64(len(peek))
		if need > limit {
			need = limit
		}
		rest := make([]byte, need)
		if _, err := io.ReadFull(br, rest); err != nil {
			return nil, err
		}
		raw := make([]byte, 0, len(peek)+len(rest))
		raw = append(raw, peek...)
		raw = append(raw, rest...)
		return raw, nil
	}
	rest, err := io.ReadAll(io.LimitReader(br, limit))
	if err != nil {
		return nil, err
	}
	raw := make([]byte, 0, len(peek)+len(rest))
	raw = append(raw, peek...)
	raw = append(raw, rest...)
	return raw, nil
}

func copyUpstreamBody(dst io.Writer, br *bufio.Reader, h http.Header, buf []byte) error {
	if transferChunked(h) {
		return copyChunked(dst, br)
	}
	if n, ok := contentLength(h); ok {
		_, err := io.CopyBuffer(dst, io.LimitReader(br, n), buf)
		return err
	}
	_, err := io.CopyBuffer(dst, br, buf)
	return err
}

func transferChunked(h http.Header) bool {
	for _, v := range h.Values("Transfer-Encoding") {
		for _, p := range strings.Split(v, ",") {
			if strings.EqualFold(strings.TrimSpace(p), "chunked") {
				return true
			}
		}
	}
	return false
}

func contentLength(h http.Header) (int64, bool) {
	v := strings.TrimSpace(h.Get("Content-Length"))
	if v == "" {
		return 0, false
	}
	n, err := strconv.ParseInt(v, 10, 64)
	if err != nil || n < 0 {
		return 0, false
	}
	return n, true
}

func copyChunked(dst io.Writer, br *bufio.Reader) error {
	for {
		line, err := br.ReadString('\n')
		if err != nil {
			return err
		}
		if _, err := dst.Write([]byte(line)); err != nil {
			return err
		}
		hexPart := strings.TrimSpace(line)
		if i := strings.IndexByte(hexPart, ';'); i >= 0 {
			hexPart = strings.TrimSpace(hexPart[:i])
		}
		size, err := strconv.ParseInt(hexPart, 16, 64)
		if err != nil {
			return err
		}
		if size == 0 {
			for {
				line, err = br.ReadString('\n')
				if err != nil {
					return err
				}
				if _, err := dst.Write([]byte(line)); err != nil {
					return err
				}
				if strings.TrimRight(line, "\r\n") == "" {
					return nil
				}
			}
		}
		if _, err := io.CopyN(dst, br, size); err != nil {
			return err
		}
		crlf := make([]byte, 2)
		if _, err := io.ReadFull(br, crlf); err != nil {
			return err
		}
		if _, err := dst.Write(crlf); err != nil {
			return err
		}
	}
}

func filterSpliceHeaders(h http.Header) http.Header {
	hop := map[string]struct{}{
		"keep-alive":          {},
		"proxy-authenticate":  {},
		"proxy-authorization": {},
		"te":                  {},
		"trailer":             {},
		"upgrade":             {},
	}
	for _, c := range h.Values("Connection") {
		for _, token := range strings.Split(c, ",") {
			if t := strings.ToLower(strings.TrimSpace(token)); t != "" {
				hop[t] = struct{}{}
			}
		}
	}
	out := make(http.Header, len(h))
	for k, vals := range h {
		if _, skip := hop[strings.ToLower(k)]; skip {
			continue
		}
		for _, v := range vals {
			out.Add(k, v)
		}
	}
	return out
}

func headerValue(headers map[string]string, name string) string {
	for k, v := range headers {
		if strings.EqualFold(k, name) {
			return v
		}
	}
	return ""
}

func tcpNoDelay(c net.Conn) {
	if tc, ok := c.(*net.TCPConn); ok {
		_ = tc.SetNoDelay(true)
	}
}

func (e entry) fetch(r *http.Request, rangeHdr string) (*http.Response, error) {
	req, err := http.NewRequestWithContext(r.Context(), http.MethodGet, e.URL, nil)
	if err != nil {
		return nil, err
	}
	applyUpstreamHeaders(req, e.Headers)
	applyPlaybackHeaders(req, r, e.Headers, rangeHdr)
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
			applyPlaybackHeaders(next, r, e.Headers, rangeHdr)
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
		if strings.TrimSpace(k) == "" || strings.TrimSpace(v) == "" || skipUpstreamHeader(k) {
			continue
		}
		req.Header.Set(k, v)
	}
}

// skipUpstreamHeader 这些头由播放器这次请求决定，不用登记值盖掉。
func skipUpstreamHeader(name string) bool {
	switch strings.ToLower(strings.TrimSpace(name)) {
	case "host", "content-length", "content-type", "connection", "transfer-encoding", "accept-encoding", "range", "if-range", "user-agent":
		return true
	default:
		return false
	}
}

// applyPlaybackHeaders 把播放器这次请求里的 Range、UA、If-Range、Accept-Encoding、Connection 写到上游。
// 播放器没带的就不写。登记头只在播放器没带 UA / Range / If-Range 时补上。
func applyPlaybackHeaders(req *http.Request, r *http.Request, registered map[string]string, rangeHdr string) {
	if rangeHdr == "" {
		rangeHdr = headerValue(registered, "range")
	}
	if rangeHdr != "" {
		req.Header.Set("Range", rangeHdr)
	}
	ua := ""
	if r != nil {
		ua = clientSpliceUA(r, registered)
	}
	if ua == "" {
		ua = headerValue(registered, "user-agent")
	}
	if ua == "" && req.URL != nil && !isLoopbackHost(req.URL.Hostname()) {
		ua = settings.PlayUA()
	}
	if ua != "" {
		req.Header.Set("User-Agent", ua)
	}
	ifRange := ""
	if r != nil {
		ifRange = strings.TrimSpace(r.Header.Get("If-Range"))
	}
	if ifRange == "" {
		ifRange = headerValue(registered, "if-range")
	}
	if ifRange != "" {
		req.Header.Set("If-Range", ifRange)
	}
	if r == nil {
		return
	}
	if ae := strings.TrimSpace(r.Header.Get("Accept-Encoding")); ae != "" {
		req.Header.Set("Accept-Encoding", ae)
	}
	conn := strings.ToLower(r.Header.Get("Connection"))
	if strings.Contains(conn, "close") {
		req.Close = true
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
