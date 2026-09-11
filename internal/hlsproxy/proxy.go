package hlsproxy

import (
	"crypto/md5"
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

	"github.com/bobo/KOTV/internal/m3u8"
	"github.com/bobo/KOTV/internal/playproxy"
	"github.com/bobo/KOTV/internal/settings"
)

const (
	pathIndex  = "/proxy/hls/index.m3u8"
	pathItem   = "/proxy/hls/item"
	mimeM3U8   = "application/vnd.apple.mpegurl; charset=utf-8"
	sessionTTL = 30 * time.Minute
)

type session struct {
	URL           string
	Headers       map[string]string
	ForcePlaylist bool
	CreatedAt     time.Time
}

type target struct {
	SessionID int
	URL       string
	CreatedAt time.Time
}

var (
	mu          sync.Mutex
	sessions    = map[int]*session{}
	targets     = map[string]*target{}
	nextSession atomic.Int32
)

// LikelyHLS 只认 path 上的 .m3u8/.m3u，忽略 query 假后缀（凤凰秀 ?id=1.m3u8 实际是 FLV）。
func LikelyHLS(raw, format string) bool {
	low := strings.ToLower(strings.TrimSpace(raw))
	if low == "" || strings.HasPrefix(low, "edl://") {
		return false
	}
	if IsProxyURL(low) {
		return false
	}
	if isHLSFormat(format) {
		return true
	}
	return pathLooksLikeHLS(raw)
}

func pathLooksLikeHLS(raw string) bool {
	u, err := url.Parse(strings.TrimSpace(raw))
	path := strings.ToLower(raw)
	if err == nil {
		path = strings.ToLower(u.EscapedPath())
	} else if i := strings.IndexAny(path, "?#"); i >= 0 {
		path = path[:i]
	}
	return strings.Contains(path, ".m3u8") || strings.HasSuffix(path, ".m3u")
}

func isHLSFormat(format string) bool {
	low := strings.ToLower(strings.TrimSpace(format))
	if low == "" {
		return false
	}
	return strings.Contains(low, "mpegurl") ||
		strings.Contains(low, "m3u8") ||
		low == "hls" ||
		strings.Contains(low, "application/vnd.apple.mpegurl") ||
		strings.Contains(low, "application/x-mpegurl")
}

// IsProxyURL 是否为本包本地 HLS 代理地址。
func IsProxyURL(raw string) bool {
	low := strings.ToLower(raw)
	return strings.Contains(low, "/proxy/hls/")
}

// ShouldOpen 是否应把该地址改写成 HLS 本地代理。
// http(s) HLS 一律代理（接口常带头发分片；无头时也统一走本地拉流）。
func ShouldOpen(raw, format string, headers map[string]string) bool {
	_ = headers
	if !LikelyHLS(raw, format) {
		return false
	}
	u, err := url.Parse(raw)
	if err != nil {
		return false
	}
	scheme := strings.ToLower(u.Scheme)
	return scheme == "http" || scheme == "https"
}

// Open 登记上游并返回本地 index.m3u8；不应代理时原样返回。
func Open(raw string, headers map[string]string) string {
	return OpenOpts(raw, headers, "", false)
}

// OpenOpts 支持 format 判定与强制按 playlist 处理（失败恢复）。
func OpenOpts(raw string, headers map[string]string, format string, forcePlaylist bool) string {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return raw
	}
	if !forcePlaylist && !ShouldOpen(raw, format, headers) {
		return raw
	}
	if forcePlaylist {
		u, err := url.Parse(raw)
		if err != nil {
			return raw
		}
		scheme := strings.ToLower(u.Scheme)
		if scheme != "http" && scheme != "https" {
			return raw
		}
	}
	id := int(nextSession.Add(1))
	now := time.Now()
	sess := &session{
		URL:           raw,
		Headers:       sanitizeHeaders(headers),
		ForcePlaylist: forcePlaylist || isHLSFormat(format),
		CreatedAt:     now,
	}
	mu.Lock()
	pruneLocked(now)
	sessions[id] = sess
	mu.Unlock()
	return fmt.Sprintf("%s%s?s=%d", playproxy.LocalHTTPBase(), pathIndex, id)
}

// HandleIndex 提供重写后的主 playlist。
func HandleIndex(w http.ResponseWriter, r *http.Request) {
	id, ok := parseSessionID(r)
	if !ok {
		http.Error(w, "missing session", http.StatusBadRequest)
		return
	}
	sess := lookupSession(id)
	if sess == nil {
		http.Error(w, "expired playlist", http.StatusNotFound)
		return
	}
	resp, err := fetchUpstream(r, sess, sess.URL, "")
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadGateway)
		return
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(io.LimitReader(resp.Body, 8<<20))
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadGateway)
		return
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		http.Error(w, fmt.Sprintf("playlist http %d", resp.StatusCode), statusFromCode(resp.StatusCode))
		return
	}
	text := string(body)
	if !looksLikePlaylist(text) && !sess.ForcePlaylist {
		http.Error(w, "invalid playlist", http.StatusBadRequest)
		return
	}
	finalURL := resp.Request.URL.String()
	text = maybeFilterPlaylist(text)
	base := absoluteProxyBase(r)
	rewritten := rewritePlaylist(text, finalURL, func(abs string) string {
		return proxyItemURL(base, id, abs)
	})
	writeNoCache(w, http.StatusOK, mimeM3U8, []byte(rewritten))
}

// HandleItem 代理嵌套 playlist 或媒体分片。
func HandleItem(w http.ResponseWriter, r *http.Request) {
	sid, ok := parseSessionID(r)
	if !ok {
		http.Error(w, "missing session", http.StatusBadRequest)
		return
	}
	tid := strings.TrimSpace(r.URL.Query().Get("id"))
	tgt := lookupTarget(tid)
	sess := lookupSession(sid)
	if tgt == nil || sess == nil || tgt.SessionID != sid {
		http.Error(w, "expired item", http.StatusNotFound)
		return
	}
	rangeHdr := ""
	if !isPlaylistPath(tgt.URL) {
		if rng := r.Header.Get("Range"); rng != "" {
			rangeHdr = rng
		}
	}
	resp, err := fetchUpstream(r, sess, tgt.URL, rangeHdr)
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadGateway)
		return
	}
	defer resp.Body.Close()
	ct := resp.Header.Get("Content-Type")
	finalURL := resp.Request.URL.String()
	asPlaylist := isPlaylistPath(tgt.URL) || isPlaylistPath(finalURL) || isPlaylistContentType(ct)
	var body []byte
	var err2 error
	if asPlaylist {
		body, err2 = io.ReadAll(io.LimitReader(resp.Body, 8<<20))
		if err2 != nil {
			http.Error(w, err2.Error(), http.StatusBadGateway)
			return
		}
		if resp.StatusCode < 200 || resp.StatusCode >= 300 {
			http.Error(w, fmt.Sprintf("nested playlist http %d", resp.StatusCode), statusFromCode(resp.StatusCode))
			return
		}
		text := string(body)
		if looksLikePlaylist(text) {
			text = maybeFilterPlaylist(text)
			base := absoluteProxyBase(r)
			rewritten := rewritePlaylist(text, finalURL, func(abs string) string {
				return proxyItemURL(base, sid, abs)
			})
			writeNoCache(w, http.StatusOK, mimeM3U8, []byte(rewritten))
			return
		}
		if !sess.ForcePlaylist {
			http.Error(w, "invalid playlist", http.StatusBadRequest)
			return
		}
		// 强制 playlist 路径但内容是媒体：按分片写出。
	} else {
		body, err2 = io.ReadAll(io.LimitReader(resp.Body, 64<<20))
		if err2 != nil {
			http.Error(w, err2.Error(), http.StatusBadGateway)
			return
		}
	}
	rawBody := body
	body = stripDisguisePrefix(body)
	stripped := len(body) != len(rawBody)
	for _, h := range []string{"Content-Type", "Accept-Ranges", "Content-Range", "ETag", "Last-Modified"} {
		if v := resp.Header.Get(h); v != "" {
			w.Header().Set(h, v)
		}
	}
	ctNow := strings.ToLower(w.Header().Get("Content-Type"))
	if stripped || strings.Contains(ctNow, "image/") || ctNow == "" {
		w.Header().Set("Content-Type", "video/MP2T")
	}
	w.Header().Set("Access-Control-Allow-Origin", "*")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("Content-Length", fmt.Sprintf("%d", len(body)))
	w.WriteHeader(resp.StatusCode)
	_, _ = w.Write(body)
}

func maybeFilterPlaylist(text string) string {
	if !looksLikePlaylist(text) || !settings.IsAdFilterEnabled() {
		return text
	}
	return m3u8.NewFilter(m3u8.DefaultConfig()).Apply(text)
}

func proxyItemURL(base string, sessionID int, abs string) string {
	id := stableTargetID(abs)
	now := time.Now()
	mu.Lock()
	if old, ok := targets[id]; ok && old.SessionID == sessionID && old.URL == abs {
		old.CreatedAt = now
	} else {
		targets[id] = &target{SessionID: sessionID, URL: abs, CreatedAt: now}
	}
	mu.Unlock()
	return fmt.Sprintf("%s%s?s=%d&id=%s", strings.TrimRight(base, "/"), pathItem, sessionID, id)
}

func stableTargetID(abs string) string {
	sum := md5.Sum([]byte(abs))
	return hex.EncodeToString(sum[:8])
}

// absoluteProxyBase 远端拉 playlist 时用请求 Host 作为分片根，避免写回 127.0.0.1。
func absoluteProxyBase(r *http.Request) string {
	if b := publicBaseFromRequest(r); b != "" {
		return b
	}
	return playproxy.LocalHTTPBase()
}

func publicBaseFromRequest(r *http.Request) string {
	if r == nil {
		return ""
	}
	host := strings.TrimSpace(r.Header.Get("X-Forwarded-Host"))
	if host != "" {
		host = strings.TrimSpace(strings.Split(host, ",")[0])
	}
	if host == "" {
		host = strings.TrimSpace(r.Host)
	}
	if host == "" {
		return ""
	}
	hostname := host
	if h, _, err := net.SplitHostPort(host); err == nil {
		hostname = h
	}
	hostname = strings.Trim(hostname, "[]")
	if hostname == "127.0.0.1" || strings.EqualFold(hostname, "localhost") || hostname == "::1" {
		return ""
	}
	scheme := "http"
	if r.TLS != nil {
		scheme = "https"
	}
	if xf := strings.TrimSpace(r.Header.Get("X-Forwarded-Proto")); xf != "" {
		scheme = strings.ToLower(strings.TrimSpace(strings.Split(xf, ",")[0]))
	}
	return scheme + "://" + host
}

func fetchUpstream(r *http.Request, sess *session, rawURL, rangeHdr string) (*http.Response, error) {
	req, err := http.NewRequestWithContext(r.Context(), http.MethodGet, rawURL, nil)
	if err != nil {
		return nil, err
	}
	applyHeaders(req, sess.Headers)
	if rangeHdr != "" {
		req.Header.Set("Range", rangeHdr)
	} else if !isPlaylistPath(rawURL) {
		req.Header.Set("Accept-Encoding", "identity")
	}
	if req.Header.Get("User-Agent") == "" {
		req.Header.Set("User-Agent", settings.PlayUA())
	}
	client := &http.Client{
		Timeout: 30 * time.Second,
		CheckRedirect: func(next *http.Request, via []*http.Request) error {
			if len(via) >= 10 {
				return fmt.Errorf("stopped after 10 redirects")
			}
			applyHeaders(next, sess.Headers)
			if rangeHdr != "" && !isPlaylistPath(rawURL) {
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

func applyHeaders(req *http.Request, headers map[string]string) {
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

func sanitizeHeaders(in map[string]string) map[string]string {
	out := make(map[string]string)
	for k, v := range in {
		k = strings.TrimSpace(k)
		v = strings.TrimSpace(v)
		if k == "" || v == "" {
			continue
		}
		out[k] = v
	}
	if _, ok := findHeader(out, "Accept"); !ok {
		out["Accept"] = "*/*"
	}
	return out
}

func findHeader(headers map[string]string, name string) (string, bool) {
	for k, v := range headers {
		if strings.EqualFold(k, name) {
			return v, true
		}
	}
	return "", false
}

func parseSessionID(r *http.Request) (int, bool) {
	s := strings.TrimSpace(r.URL.Query().Get("s"))
	if s == "" {
		return 0, false
	}
	var id int
	if _, err := fmt.Sscanf(s, "%d", &id); err != nil || id <= 0 {
		return 0, false
	}
	return id, true
}

func lookupSession(id int) *session {
	mu.Lock()
	defer mu.Unlock()
	pruneLocked(time.Now())
	return sessions[id]
}

func lookupTarget(id string) *target {
	if id == "" {
		return nil
	}
	mu.Lock()
	defer mu.Unlock()
	pruneLocked(time.Now())
	return targets[id]
}

func pruneLocked(now time.Time) {
	for id, s := range sessions {
		if now.Sub(s.CreatedAt) > sessionTTL {
			delete(sessions, id)
		}
	}
	for id, t := range targets {
		if now.Sub(t.CreatedAt) > sessionTTL {
			delete(targets, id)
			continue
		}
		if _, ok := sessions[t.SessionID]; !ok {
			delete(targets, id)
		}
	}
}

func writeNoCache(w http.ResponseWriter, code int, contentType string, body []byte) {
	w.Header().Set("Content-Type", contentType)
	w.Header().Set("Access-Control-Allow-Origin", "*")
	w.Header().Set("Cache-Control", "no-cache")
	w.Header().Set("Content-Length", fmt.Sprintf("%d", len(body)))
	w.WriteHeader(code)
	_, _ = w.Write(body)
}

func statusFromCode(code int) int {
	if code >= 400 && code < 600 {
		return code
	}
	return http.StatusBadGateway
}
