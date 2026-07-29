package spider

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/bobo/KOTV/internal/localproxy"
	"github.com/bobo/KOTV/internal/paths"
	"github.com/bobo/KOTV/internal/spider/embedpy"
	"github.com/bobo/KOTV/internal/util"

	_ "embed"
)

//go:embed pyrunner.py
var pyRunnerSrc string

//go:embed pybase.py
var pyBaseSrc string

const pyCallTimeout = 45 * time.Second

var ErrScriptInterrupted = errors.New("脚本调用已中断")

var (
	jsPyMu      sync.Mutex
	jsPy        = map[string]Spider{}
	recentJsKey string
	recentPyKey string
)

type pySpider struct {
	key, api, ext, jar string
	scriptPath         string
	embedSID           uintptr

	mu     sync.Mutex
	epoch  atomic.Uint64
	nextID atomic.Uint64
	inited bool
}

func newPySpider(key, api, ext, jar string) Spider {
	jsPyMu.Lock()
	defer jsPyMu.Unlock()
	if s, ok := jsPy[jsPyKey(key, "py")]; ok {
		return s
	}
	s := &pySpider{key: key, api: api, ext: ext, jar: jar}
	jsPy[jsPyKey(key, "py")] = s
	return s
}

func clearJsPy() {
	jsPyMu.Lock()
	spiders := make([]Spider, 0, len(jsPy))
	for _, s := range jsPy {
		spiders = append(spiders, s)
	}
	jsPy = map[string]Spider{}
	recentJsKey = ""
	recentPyKey = ""
	jsPyMu.Unlock()
	for _, s := range spiders {
		s.Destroy()
	}
}

func jsPyKey(key, kind string) string { return kind + ":" + key }

func setRecentJs(key string) {
	jsPyMu.Lock()
	recentJsKey = key
	jsPyMu.Unlock()
}

func setRecentPy(key string) {
	jsPyMu.Lock()
	recentPyKey = key
	jsPyMu.Unlock()
}

func recentJsSpider() Spider {
	jsPyMu.Lock()
	defer jsPyMu.Unlock()
	if recentJsKey == "" {
		return nil
	}
	return jsPy[jsPyKey(recentJsKey, "js")]
}

func recentPySpider() Spider {
	jsPyMu.Lock()
	defer jsPyMu.Unlock()
	if recentPyKey == "" {
		return nil
	}
	return jsPy[jsPyKey(recentPyKey, "py")]
}

// InterruptScriptSpiders 打断正在运行的 Python/JavaScript 调用。
func InterruptScriptSpiders() {
	jsPyMu.Lock()
	spiders := make([]Spider, 0, len(jsPy))
	for _, s := range jsPy {
		spiders = append(spiders, s)
	}
	jsPyMu.Unlock()
	for _, spider := range spiders {
		switch s := spider.(type) {
		case *pySpider:
			s.interrupt()
		case *jsSpider:
			s.interrupt()
		}
	}
}

func (s *pySpider) ensureScript() (string, error) {
	if s.scriptPath != "" {
		return s.scriptPath, nil
	}
	if st, err := os.Stat(s.api); err == nil && !st.IsDir() {
		s.scriptPath = s.api
		return s.api, nil
	}
	dest := filepath.Join(paths.PyCache(), util.MD5(s.api)+".py")
	if st, err := os.Stat(dest); err == nil && st.Size() > 0 {
		s.scriptPath = dest
		return dest, nil
	}
	data, err := util.HTTPGet(s.api, nil)
	if err != nil {
		return "", err
	}
	if err := os.WriteFile(dest, []byte(data), 0o644); err != nil {
		return "", err
	}
	s.scriptPath = dest
	return dest, nil
}

func pyRunnerPath() (string, error) {
	dest := filepath.Join(paths.PyCache(), "_kotv_runner.py")
	current, _ := os.ReadFile(dest)
	if !bytes.Equal(current, []byte(pyRunnerSrc)) {
		if err := os.WriteFile(dest, []byte(pyRunnerSrc), 0o644); err != nil {
			return "", err
		}
	}
	baseDir := filepath.Join(paths.PyCache(), "base")
	if err := os.MkdirAll(baseDir, 0o755); err != nil {
		return "", err
	}
	if err := os.WriteFile(filepath.Join(baseDir, "__init__.py"), nil, 0o644); err != nil {
		return "", err
	}
	basePath := filepath.Join(baseDir, "spider.py")
	current, _ = os.ReadFile(basePath)
	if !bytes.Equal(current, []byte(pyBaseSrc)) {
		if err := os.WriteFile(basePath, []byte(pyBaseSrc), 0o644); err != nil {
			return "", err
		}
	}
	return dest, nil
}

func (s *pySpider) run(method string, args map[string]interface{}) (string, error) {
	s.mu.Lock()
	defer s.mu.Unlock()

	if runtime.GOOS == "android" {
		return s.runAndroidLocked(method, args)
	}
	if !embedpy.Active {
		return "", fmt.Errorf("嵌入 Python 不可用：请以 CGO_ENABLED=1 构建")
	}
	return s.runEmbedLocked(method, args)
}

func (s *pySpider) runEmbedLocked(method string, args map[string]interface{}) (string, error) {
	script, err := s.ensureScript()
	if err != nil {
		return "", err
	}
	runner, err := pyRunnerPath()
	if err != nil {
		return "", err
	}
	startEpoch := s.epoch.Load()
	if err := s.startEmbedLocked(runner, script); err != nil {
		return "", err
	}
	if !s.inited && method != "init" {
		if _, err := s.callEmbedLocked(startEpoch, "init", map[string]interface{}{"extend": s.ext}); err != nil {
			s.stopEmbedLocked()
			return "", err
		}
		s.inited = true
	}
	out, err := s.callEmbedLocked(startEpoch, method, args)
	if err != nil {
		return "", err
	}
	if method == "init" {
		s.inited = true
	}
	return out, nil
}

func (s *pySpider) startEmbedLocked(runner, script string) error {
	if s.embedSID != 0 {
		return nil
	}
	sid, err := embedpy.StartSession(runner, script, s.key, s.ext, s.api, paths.PyCache())
	if err != nil {
		return err
	}
	s.embedSID = sid
	return nil
}

func (s *pySpider) callEmbedLocked(startEpoch uint64, method string, args map[string]interface{}) (string, error) {
	reqID := s.nextID.Add(1)
	payload := map[string]interface{}{
		"id":     reqID,
		"method": method,
		"args":   args,
	}
	body, err := json.Marshal(payload)
	if err != nil {
		return "", err
	}
	line, err := embedpy.CallSession(s.embedSID, string(body))
	if s.epoch.Load() != startEpoch {
		s.stopEmbedLocked()
		return "", ErrScriptInterrupted
	}
	if err != nil {
		s.stopEmbedLocked()
		return "", err
	}
	var response struct {
		ID     uint64          `json:"id"`
		OK     bool            `json:"ok"`
		Result json.RawMessage `json:"result"`
		Error  string          `json:"error"`
	}
	if err := json.Unmarshal([]byte(line), &response); err != nil {
		return "", fmt.Errorf("Python 响应无效: %w", err)
	}
	if !response.OK {
		return "", fmt.Errorf("Python %s 失败: %s", method, response.Error)
	}
	var text string
	if len(response.Result) == 0 || string(response.Result) == "null" {
		return "{}", nil
	}
	if err := json.Unmarshal(response.Result, &text); err == nil {
		return strings.TrimSpace(text), nil
	}
	return strings.TrimSpace(string(response.Result)), nil
}

func (s *pySpider) stopEmbedLocked() {
	if s.embedSID != 0 {
		embedpy.StopSession(s.embedSID)
		s.embedSID = 0
	}
	s.inited = false
}

func (s *pySpider) runAndroidLocked(method string, args map[string]interface{}) (string, error) {
	script, err := s.ensureScript()
	if err != nil {
		return "", err
	}
	runner, err := pyRunnerPath()
	if err != nil {
		return "", err
	}

	// Android：不启动独立 Python 进程；每次通过 HTTP 触发一次 runner exec。
	// 对齐 Go 侧语义：init 只跑一次。
	if !s.inited && method != "init" {
		if _, err := s.androidCallPythonLocked("init", map[string]interface{}{"extend": s.ext}, script, runner); err != nil {
			return "", err
		}
		s.inited = true
	}

	out, err := s.androidCallPythonLocked(method, args, script, runner)
	if err != nil {
		return "", err
	}
	if method == "init" {
		s.inited = true
	}
	return out, nil
}

func (s *pySpider) androidCallPythonLocked(method string, args map[string]interface{}, scriptPath, runnerPath string) (string, error) {
	const base = "http://127.0.0.1:9979"
	payload := map[string]interface{}{
		"runnerPath": runnerPath,
		"scriptPath": scriptPath,
		"key":         s.key,
		"ext":         s.ext,
		"api":         s.api,
		"cacheRoot":  paths.PyCache(),
		"proxyPort":   localproxy.Port(),
		"method":      method,
		"args":        args,
	}
	body, err := json.Marshal(payload)
	if err != nil {
		return "", err
	}
	req, err := http.NewRequest(http.MethodPost, base+"/py/call", bytes.NewReader(body))
	if err != nil {
		return "", err
	}
	req.Header.Set("Content-Type", "application/json; charset=utf-8")
	client := &http.Client{Timeout: pyCallTimeout}
	resp, err := client.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()

	b, _ := io.ReadAll(io.LimitReader(resp.Body, 2<<20))
	if resp.StatusCode >= 400 {
		return "", fmt.Errorf("android py call failed: http=%d %s", resp.StatusCode, strings.TrimSpace(string(b)))
	}

	// Android 服务成功响应：{"result":"..."}；失败响应：{"ok":false,"error":"..."}。
	var wrap struct {
		OK     *bool       `json:"ok"`
		Error  string      `json:"error"`
		Result interface{} `json:"result"`
	}
	if err := json.Unmarshal(b, &wrap); err != nil {
		return "", fmt.Errorf("android py call invalid json: %w", err)
	}
	if wrap.OK != nil && !*wrap.OK {
		return "", fmt.Errorf("android py call failed: %s", wrap.Error)
	}
	if wrap.Error != "" {
		return "", fmt.Errorf("android py call failed: %s", wrap.Error)
	}
	if wrap.Result == nil {
		return "{}", nil
	}
	// 返回值在 runner 中通常是 JSON 字符串或普通字符串；Go 侧后续会再做 json.Unmarshal。
	switch v := wrap.Result.(type) {
	case string:
		return strings.TrimSpace(v), nil
	default:
		return strings.TrimSpace(fmt.Sprint(v)), nil
	}
}

func (s *pySpider) stopLocked() {
	s.stopEmbedLocked()
}

func (s *pySpider) interrupt() {
	// 只抬 epoch：CallSession 持全局 apiMu 时若在此 StopSession 会死锁。
	// 调用返回后 callEmbedLocked 发现世代变化会 stopEmbedLocked。
	s.epoch.Add(1)
}

func (s *pySpider) Init(ext string) error {
	// 对齐 TV PyLoader.getSpider：computeIfAbsent 后 init 只一次。
	s.mu.Lock()
	if s.inited {
		s.mu.Unlock()
		return nil
	}
	s.ext = ext
	s.mu.Unlock()
	_, err := s.run("init", map[string]interface{}{"extend": ext})
	return err
}

func (s *pySpider) HomeContent(filter bool) (string, error) {
	return s.run("homeContent", map[string]interface{}{"filter": filter})
}
func (s *pySpider) HomeVideoContent() (string, error) { return s.run("homeVideoContent", nil) }
func (s *pySpider) CategoryContent(tid, pg string, filter bool, extend map[string]string) (string, error) {
	return s.run("categoryContent", map[string]interface{}{"tid": tid, "pg": pg, "filter": filter, "extend": extend})
}
func (s *pySpider) DetailContent(ids []string) (string, error) {
	return s.run("detailContent", map[string]interface{}{"ids": ids})
}
func (s *pySpider) SearchContent(key string, quick bool, pg string) (string, error) {
	return s.run("searchContent", map[string]interface{}{"key": key, "quick": quick, "pg": pg})
}
func (s *pySpider) PlayerContent(flag, id string, vipFlags []string) (string, error) {
	return s.run("playerContent", map[string]interface{}{"flag": flag, "id": id, "vipFlags": vipFlags})
}
func (s *pySpider) LiveContent(url string) (string, error) {
	return s.run("liveContent", map[string]interface{}{"url": url})
}
func (s *pySpider) Proxy(params map[string]string) (int, string, []byte, map[string]string, error) {
	raw, err := s.run("localProxy", map[string]interface{}{"params": params})
	if err != nil {
		return 0, "", nil, nil, err
	}
	status, contentType, body, headers, parseErr := parseCatvodProxy(raw)
	return status, contentType, body, headers, parseErr
}

func (s *pySpider) Action(action string) (string, error) {
	return s.run("action", map[string]interface{}{"action": action})
}

func (s *pySpider) ManualVideoCheck() (bool, error) {
	raw, err := s.run("manualVideoCheck", nil)
	if err != nil {
		return false, err
	}
	return parseJSTruthy(raw), nil
}

func (s *pySpider) IsVideoFormat(u string) (bool, error) {
	raw, err := s.run("isVideoFormat", map[string]interface{}{"url": u})
	if err != nil {
		return false, err
	}
	return parseJSTruthy(raw), nil
}

func (s *pySpider) Destroy() {
	s.mu.Lock()
	if s.embedSID != 0 && s.inited {
		_, _ = s.callEmbedLocked(s.epoch.Load(), "destroy", map[string]interface{}{})
	}
	s.stopLocked()
	s.mu.Unlock()
	s.interrupt()
}
