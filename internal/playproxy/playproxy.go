package playproxy

import (
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"io"
	"net/http"
	"strings"
	"sync"
	"time"
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
)

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
	port := 9978
	if portFn != nil {
		if p := portFn(); p > 0 {
			port = p
		}
	}
	return fmt.Sprintf("http://127.0.0.1:%d/proxy/play?id=%s", port, id)
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
	req, err := http.NewRequestWithContext(r.Context(), http.MethodGet, e.URL, nil)
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadGateway)
		return
	}
	for k, v := range e.Headers {
		req.Header.Set(k, v)
	}
	// 播放列表不要透传 Range：VLC 常带 bytes=0-，上游若回 206 会截断/搞坏 m3u8。
	if !isPlaylistURL(e.URL) {
		if rng := r.Header.Get("Range"); rng != "" && !isFullFileRange(rng) {
			req.Header.Set("Range", rng)
		}
	}
	if req.Header.Get("User-Agent") == "" {
		req.Header.Set("User-Agent", "Mozilla/5.0 KOTV")
	}
	resp, err := http.DefaultClient.Do(req)
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
	w.WriteHeader(resp.StatusCode)
	_, _ = io.Copy(writeOnly{w}, resp.Body)
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
