package server

import (
	"embed"
	"encoding/json"
	"fmt"
	"io"
	"io/fs"
	"log"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"

	"github.com/bobo/KOTV/internal/config"
	"github.com/bobo/KOTV/internal/localproxy"
	m3u8cache "github.com/bobo/KOTV/internal/m3u8"
	"github.com/bobo/KOTV/internal/paths"
	"github.com/bobo/KOTV/internal/playproxy"
	"github.com/bobo/KOTV/internal/settings"
	"github.com/bobo/KOTV/internal/spider"
	"github.com/bobo/KOTV/internal/thunder"
)

//go:embed resources
var remoteFS embed.FS

const defaultPort = 9978
const maxPort = 9999

// Server 局域网 HTTP 遥控服务，对应 KtorD。
type Server struct {
	mu            sync.RWMutex
	port          int
	http          *http.Server
	events        *Events
	onAction      func(Action)
	uiReply       *uiReplyStore
	mediaProvider func() map[string]string
	syncHandler   *SyncHandler
	contentAPI    ContentAPI
	onShutdown    func()
}

type Action struct {
	Do      string
	Keyword string
	URL     string
	Text    string
	Config  string
	Name    string
	Type    string
	Path    string
	SeekMs  int64
	Device  string // do=cast：对端设备 JSON
	History string // do=cast：历史 JSON
}

var defaultServer *Server

func Default() *Server { return defaultServer }

func New(onAction func(Action)) *Server {
	s := &Server{events: NewEvents(), onAction: onAction, uiReply: newUIReplyStore()}
	defaultServer = s
	return s
}

func (s *Server) Port() int {
	s.mu.RLock()
	defer s.mu.RUnlock()
	if s.port > 0 {
		return s.port
	}
	return defaultPort
}

func (s *Server) Events() *Events { return s.events }

func (s *Server) SetMediaProvider(fn func() map[string]string) {
	s.mu.Lock()
	s.mediaProvider = fn
	s.mu.Unlock()
}

func (s *Server) Start() error {
	mux := http.NewServeMux()
	remote, _ := fs.Sub(remoteFS, "resources")
	remoteServer := http.FileServer(http.FS(remote))
	// assets:// 映射到根路径，优先命中本地 assets 目录，否则回落遥控 UI。
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		if rel := strings.TrimPrefix(r.URL.Path, "/"); rel != "" && rel != "index.html" {
			if candidate, ok := safeAssetPath(rel); ok {
				if st, err := os.Stat(candidate); err == nil && !st.IsDir() {
					http.ServeFile(w, r, candidate)
					return
				}
			}
		}
		remoteServer.ServeHTTP(w, r)
	})
	mux.HandleFunc("/proxy/cached_m3u8", s.handleCachedM3U8)
	mux.HandleFunc("/proxy/play", playproxy.Handle)
	mux.HandleFunc("/proxy/bt/", thunder.Handle)
	mux.HandleFunc("/proxy", s.handleSpiderProxy)
	mux.HandleFunc("/file/", s.handleFile)
	mux.HandleFunc("/upload", s.handleUpload)
	mux.HandleFunc("/newFolder", s.handleNewFolder)
	mux.HandleFunc("/delFolder", s.handleDelPath)
	mux.HandleFunc("/delFile", s.handleDelPath)
	mux.HandleFunc("/cache", s.handleCache)
	mux.HandleFunc("/action", s.handleAction)
	mux.HandleFunc("/postMsg", s.handlePostMsg)
	mux.HandleFunc("/uiReply", s.handleUIReply)
	mux.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("ok"))
	})
	s.registerAPIv1(mux)
	mux.HandleFunc("/media", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json; charset=utf-8")
		s.mu.RLock()
		fn := s.mediaProvider
		s.mu.RUnlock()
		data := map[string]string{"state": "idle", "title": "未播放", "position": "0", "duration": "0", "playing": "false"}
		if fn != nil {
			if m := fn(); m != nil {
				data = m
			}
		}
		_ = json.NewEncoder(w).Encode(data)
	})
	mux.HandleFunc("/device", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(map[string]string{
			"name": "KO影视",
			"ip":   localIP(),
			"uuid": settings.EnsureDeviceUUID(),
		})
	})

	var ln net.Listener
	var err error
	for port := defaultPort; port <= maxPort; port++ {
		// 绑定所有接口以便 DLNA 设备访问本地代理
		ln, err = net.Listen("tcp", fmt.Sprintf("0.0.0.0:%d", port))
		if err == nil {
			s.mu.Lock()
			s.port = port
			s.mu.Unlock()
			localproxy.SetPort(port)
			playproxy.SetPortFunc(func() int { return port })
			thunder.SetPortFunc(func() int { return port })
			break
		}
	}
	if ln == nil {
		return fmt.Errorf("无法启动 HTTP 服务: %w", err)
	}

	s.http = &http.Server{Handler: cors(mux)}
	go func() {
		log.Printf("HTTP 遥控服务已启动: http://127.0.0.1:%d", s.port)
		if err := s.http.Serve(ln); err != nil && err != http.ErrServerClosed {
			log.Printf("HTTP 服务异常: %v", err)
		}
	}()
	return nil
}

// safeAssetPath 把相对路径解析到本地 assets 根内，防止路径穿越。
func safeAssetPath(rel string) (string, bool) {
	root := paths.Assets()
	candidate := filepath.Clean(filepath.Join(root, filepath.FromSlash(rel)))
	if candidate != root && !strings.HasPrefix(candidate, root+string(os.PathSeparator)) {
		return "", false
	}
	return candidate, true
}

func (s *Server) Stop() {
	if s.http != nil {
		_ = s.http.Close()
	}
}

// handlePostMsg 承接爬虫 jar Util.notify / UiBridge（GET/POST ?msg=）。
func (s *Server) handlePostMsg(w http.ResponseWriter, r *http.Request) {
	msg := strings.TrimSpace(r.URL.Query().Get("msg"))
	if r.Method == http.MethodPost {
		_ = r.ParseForm()
		if v := strings.TrimSpace(r.Form.Get("msg")); v != "" {
			msg = v
		}
		if msg == "" {
			// Declarative UI documents may include compact images; keep a generous bound.
			body, _ := io.ReadAll(io.LimitReader(r.Body, 2<<20))
			msg = strings.TrimSpace(string(body))
		}
	}
	if msg == "" {
		http.Error(w, "missing msg", http.StatusBadRequest)
		return
	}
	s.events.EmitPostMsg(msg)
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write([]byte("ok"))
}

func (s *Server) handleAction(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	if r.Method == http.MethodPost {
		_ = r.ParseForm()
		for k, v := range r.PostForm {
			if len(v) > 0 {
				q.Set(k, v[0])
			}
		}
	}
	action := Action{
		Do:      q.Get("do"),
		Keyword: first(q.Get("keyword"), q.Get("word")),
		URL:     first(q.Get("url"), q.Get("push")),
		Text:    q.Get("text"),
		Config:  first(q.Get("config"), q.Get("text")),
		Name:    q.Get("name"),
		Type:    q.Get("type"),
		Path:    q.Get("path"),
		Device:  q.Get("device"),
		History: q.Get("history"),
	}
	if v := q.Get("seek"); v != "" {
		if ms, err := strconv.ParseInt(v, 10, 64); err == nil {
			action.SeekMs = ms
		}
	}
	switch action.Do {
	case "search":
		s.events.EmitSearch(action.Keyword)
	case "push":
		s.events.EmitPush(action.URL)
	case "danmaku":
		s.events.EmitDanmaku(action.Text)
	case "setting":
		s.events.EmitSetting(action.Config, action.Name)
	case "control":
		s.events.EmitControl(action.Type, action.SeekMs)
	case "file":
		s.dispatchFileAction(action.Path)
	case "cast":
		s.events.EmitCast(action.Config, action.Device, action.History)
	case "refresh":
		typ := action.Type
		if typ == "" {
			typ = "detail"
		}
		path := action.Path
		if path == "" {
			path = action.URL
		}
		s.events.EmitRefresh(typ, path)
	case "sync":
		qmap := map[string]string{}
		for k := range q {
			qmap[k] = q.Get(k)
		}
		s.handleSync(w, r, qmap)
		return
	}
	if s.onAction != nil {
		s.onAction(action)
	}
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write([]byte("OK"))
}

func (s *Server) handleCachedM3U8(w http.ResponseWriter, r *http.Request) {
	id := r.URL.Query().Get("id")
	if id == "" {
		http.Error(w, "missing id", http.StatusBadRequest)
		return
	}
	content, ok := m3u8cache.DefaultCache.Get(id)
	if !ok {
		http.Error(w, "not found", http.StatusNotFound)
		return
	}
	w.Header().Set("Content-Type", "application/vnd.apple.mpegurl")
	w.Header().Set("Access-Control-Allow-Origin", "*")
	_, _ = w.Write([]byte(content))
}

func (s *Server) handleSpiderProxy(w http.ResponseWriter, r *http.Request) {
	params := map[string]string{}
	for key, values := range r.URL.Query() {
		if len(values) > 0 {
			params[key] = values[0]
		}
	}
	// 合并请求头与表单
	for key, values := range r.Header {
		if len(values) == 0 {
			continue
		}
		lk := strings.ToLower(key)
		if lk == "host" || lk == "connection" || lk == "content-length" {
			continue
		}
		if _, exists := params[key]; !exists {
			params[key] = values[0]
		}
	}
	if r.Method == http.MethodPost {
		_ = r.ParseForm()
		for key, values := range r.PostForm {
			if len(values) > 0 {
				params[key] = values[0]
			}
		}
	}
	if params["do"] == "ck" {
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		_, _ = w.Write([]byte("ok"))
		return
	}
	cfg := config.Default()
	if cfg == nil {
		http.Error(w, "config not ready", http.StatusServiceUnavailable)
		return
	}
	siteKey := params["siteKey"]
	if siteKey == "" {
		status, contentType, body, headers, err := spider.GlobalProxy(params)
		if err != nil {
			http.Error(w, err.Error(), http.StatusBadGateway)
			return
		}
		writeProxyResponse(w, status, contentType, body, headers)
		return
	}
	// 对齐 TV BaseLoader.getSpider(key)：先 Site，再 Live。
	if site := cfg.GetSite(siteKey); site != nil && site.Key != "" {
		status, contentType, body, headers, err := cfg.Spider(*site).Proxy(params)
		if err != nil {
			http.Error(w, err.Error(), http.StatusBadGateway)
			return
		}
		writeProxyResponse(w, status, contentType, body, headers)
		return
	}
	if live := cfg.GetLive(siteKey); live != nil && live.Name != "" {
		api := strings.TrimSpace(live.API)
		if api == "" {
			http.Error(w, "live api empty", http.StatusNotFound)
			return
		}
		jar := live.JAR
		if jar == "" {
			jar = cfg.API().Spider
		}
		ext := live.Ext.String()
		sp := spider.Get(live.Name, api, ext, jar)
		spider.SetRecent(live.Name, api, jar)
		status, contentType, body, headers, err := sp.Proxy(params)
		if err != nil {
			http.Error(w, err.Error(), http.StatusBadGateway)
			return
		}
		writeProxyResponse(w, status, contentType, body, headers)
		return
	}
	http.Error(w, "site not found", http.StatusNotFound)
}

func writeProxyResponse(w http.ResponseWriter, status int, contentType string, body []byte, headers map[string]string) {
	if status <= 0 {
		status = http.StatusOK
	}
	// 溢写文件：大响应体不经内存缓冲，直接从磁盘流式回写客户端后删除。
	bodyFile := headers[spider.ProxyBodyFileHeader]
	if contentType != "" {
		w.Header().Set("Content-Type", contentType)
	}
	for k, v := range headers {
		if skipProxyResponseHeader(k) {
			continue
		}
		if strings.EqualFold(k, "content-type") && contentType != "" {
			continue
		}
		w.Header().Set(k, v)
	}
	w.Header().Set("Access-Control-Allow-Origin", "*")

	if bodyFile != "" {
		defer os.Remove(bodyFile)
		f, err := os.Open(bodyFile)
		if err != nil {
			http.Error(w, err.Error(), http.StatusBadGateway)
			return
		}
		defer f.Close()
		if info, err := f.Stat(); err == nil {
			// m3u8 改写后体积会变大；必须按真实文件大小重写 Content-Length，
			// 否则客户端只读旧长度，尾巴污染 keep-alive，后续 TS 全部失败。
			w.Header().Set("Content-Length", strconv.FormatInt(info.Size(), 10))
		} else {
			w.Header().Del("Content-Length")
		}
		w.WriteHeader(status)
		_, _ = io.Copy(writeOnly{w}, f)
		return
	}

	w.Header().Set("Content-Length", strconv.Itoa(len(body)))
	w.WriteHeader(status)
	_, _ = w.Write(body)
}

func skipProxyResponseHeader(name string) bool {
	switch {
	case strings.EqualFold(name, spider.ProxyBodyFileHeader),
		strings.EqualFold(name, "content-length"),
		strings.EqualFold(name, "transfer-encoding"),
		strings.EqualFold(name, "connection"),
		strings.EqualFold(name, "keep-alive"),
		strings.EqualFold(name, "proxy-connection"),
		strings.EqualFold(name, "trailer"),
		strings.EqualFold(name, "upgrade"),
		// body 已由 bridge 解码落盘/入内存时，上游 Content-Encoding 不能再转给客户端。
		strings.EqualFold(name, "content-encoding"):
		return true
	default:
		return false
	}
}

// writeOnly 禁用 ResponseWriter.ReadFrom，避免 sendfile 绕过 Content-Length 约束。
type writeOnly struct{ http.ResponseWriter }

func (w writeOnly) Write(p []byte) (int, error) { return w.ResponseWriter.Write(p) }

func first(a, b string) string {
	if a != "" {
		return a
	}
	return b
}

func localIP() string {
	ifaces, err := net.Interfaces()
	if err != nil {
		return "127.0.0.1"
	}
	for _, iface := range ifaces {
		if iface.Flags&net.FlagUp == 0 || iface.Flags&net.FlagLoopback != 0 {
			continue
		}
		addrs, err := iface.Addrs()
		if err != nil {
			continue
		}
		for _, addr := range addrs {
			var ip net.IP
			switch v := addr.(type) {
			case *net.IPNet:
				ip = v.IP
			case *net.IPAddr:
				ip = v.IP
			}
			if ip == nil || ip.IsLoopback() {
				continue
			}
			ip = ip.To4()
			if ip != nil {
				return ip.String()
			}
		}
	}
	return "127.0.0.1"
}

func cors(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Access-Control-Allow-Origin", "*")
		w.Header().Set("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
		w.Header().Set("Access-Control-Allow-Headers", "*")
		if r.Method == http.MethodOptions {
			w.WriteHeader(http.StatusNoContent)
			return
		}
		next.ServeHTTP(w, r)
	})
}

// ProxyPort 供爬虫代理使用的端口字符串。
func (s *Server) ProxyPort() string {
	return strconv.Itoa(s.Port())
}

// MatchPushURL 判断是否为可推送的播放链接（含本地路径 / file://）。
func MatchPushURL(u string) bool {
	u = strings.TrimSpace(u)
	if u == "" {
		return false
	}
	low := strings.ToLower(u)
	switch {
	case strings.HasPrefix(low, "http://"), strings.HasPrefix(low, "https://"),
		strings.HasPrefix(low, "file://"), strings.HasPrefix(low, "magnet:"),
		strings.HasPrefix(low, "thunder:"):
		return true
	}
	for _, ext := range videoExts {
		if strings.HasSuffix(low, ext) {
			return true
		}
	}
	if filepath.IsAbs(u) {
		if st, err := os.Stat(u); err == nil && !st.IsDir() {
			return true
		}
	}
	return false
}

var videoExts = []string{
	".m3u8", ".mp4", ".mkv", ".avi", ".mov", ".flv", ".webm", ".ts", ".m4v", ".mpd", ".wmv", ".rmvb",
}

var subtitleExts = []string{".srt", ".ssa", ".ass", ".vtt"}

func dispatchPathLooksLike(path string, exts []string) bool {
	low := strings.ToLower(path)
	for _, ext := range exts {
		if strings.HasSuffix(low, ext) {
			return true
		}
	}
	return false
}

func (s *Server) dispatchFileAction(raw string) {
	path := strings.TrimSpace(raw)
	path = strings.TrimPrefix(path, "file://")
	path = strings.TrimPrefix(path, "file:")
	if path == "" {
		return
	}
	switch {
	case dispatchPathLooksLike(path, subtitleExts):
		s.events.EmitRefresh("subtitle", path)
	case strings.HasSuffix(strings.ToLower(path), ".xml") ||
		(strings.HasSuffix(strings.ToLower(path), ".json") && strings.Contains(strings.ToLower(path), "danmaku")):
		s.events.EmitRefresh("danmaku", path)
	case MatchPushURL(path) || dispatchPathLooksLike(path, videoExts):
		s.events.EmitPush(path)
	case strings.HasSuffix(strings.ToLower(path), ".json") || strings.HasSuffix(strings.ToLower(path), ".txt"):
		s.events.EmitSetting(path, filepath.Base(path))
	default:
		if MatchPushURL(path) {
			s.events.EmitPush(path)
		}
	}
}
