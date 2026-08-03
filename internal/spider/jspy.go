package spider

import (
	"bufio"
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	goruntime "runtime"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/bobo/KOTV/internal/hostclient"
	"github.com/bobo/KOTV/internal/localproxy"
	"github.com/bobo/KOTV/internal/paths"
	appruntime "github.com/bobo/KOTV/internal/runtime"
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
	sessionSlot        int // 进程池 slot，Android session 隔离用

	mu           sync.Mutex
	cmd          *exec.Cmd
	stdin        io.WriteCloser
	stdout       *bufio.Reader
	proc         atomic.Pointer[os.Process]
	epoch        atomic.Uint64
	nextID       atomic.Uint64
	inited       bool
	activeClient atomic.Value // string
}

func (s *pySpider) activeClientID() string {
	v, _ := s.activeClient.Load().(string)
	return v
}

func newPySpider(key, api, ext, jar string) Spider {
	jsPyMu.Lock()
	defer jsPyMu.Unlock()
	ck := jsPyKey("py", key, api, ext, jar)
	if s, ok := jsPy[ck]; ok {
		return s
	}
	s := newPyPool(key, api, ext, jar)
	jsPy[ck] = s
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

// jsPyKey 与 jar 一致：含 userId，避免多用户同站 key 撞缓存。
func jsPyKey(kind, key, api, ext, jar string) string {
	uid := hostclient.CurrentUserID()
	return uid + "\x01" + kind + ":" + key + "\x00" + api + "\x00" + ext + "\x00" + jar
}

// DestroyUserScripts 销毁指定用户的全部 Py/JS 池。
func DestroyUserScripts(userID string) {
	userID = strings.TrimSpace(userID)
	if userID == "" {
		return
	}
	prefix := userID + "\x01"
	jsPyMu.Lock()
	var doomed []Spider
	for k, s := range jsPy {
		if strings.HasPrefix(k, prefix) {
			doomed = append(doomed, s)
			delete(jsPy, k)
		}
	}
	jsPyMu.Unlock()
	for _, s := range doomed {
		s.Destroy()
	}
}

func setRecentJs(key, api, ext, jar string) {
	jsPyMu.Lock()
	recentJsKey = jsPyKey("js", key, api, ext, jar)
	jsPyMu.Unlock()
}

func setRecentPy(key, api, ext, jar string) {
	jsPyMu.Lock()
	recentPyKey = jsPyKey("py", key, api, ext, jar)
	jsPyMu.Unlock()
}

func recentJsSpider() Spider {
	jsPyMu.Lock()
	defer jsPyMu.Unlock()
	if recentJsKey == "" {
		return nil
	}
	return jsPy[recentJsKey]
}

func recentPySpider() Spider {
	jsPyMu.Lock()
	defer jsPyMu.Unlock()
	if recentPyKey == "" {
		return nil
	}
	return jsPy[recentPyKey]
}

// InterruptScriptSpiders 打断正在运行的全部 Python/JavaScript 调用。
func InterruptScriptSpiders() {
	InterruptScriptSpidersForClient("")
}

// InterruptScriptSpidersForClient 仅打断属于指定 clientId 的进行中脚本调用；空串表示全部。
func InterruptScriptSpidersForClient(clientID string) {
	jsPyMu.Lock()
	spiders := make([]Spider, 0, len(jsPy))
	for _, s := range jsPy {
		spiders = append(spiders, s)
	}
	jsPyMu.Unlock()
	for _, spider := range spiders {
		switch s := spider.(type) {
		case *pyPool:
			if clientID == "" || s.matchesClient(clientID) {
				s.interrupt()
			}
		case *pySpider:
			if clientID == "" || s.activeClientID() == clientID {
				s.interrupt()
			}
		case *jsPool:
			if clientID == "" || s.matchesClient(clientID) {
				s.interrupt()
			}
		case *jsSpider:
			if clientID == "" || s.activeClientID() == clientID {
				s.interrupt()
			}
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
	cid := hostclient.Current()
	s.activeClient.Store(cid)
	defer s.activeClient.Store("")

	if goruntime.GOOS == "android" {
		return s.runAndroidLocked(method, args)
	}

	script, err := s.ensureScript()
	if err != nil {
		return "", err
	}
	python := appruntime.Python()
	if python == "" {
		return "", fmt.Errorf("未找到捆绑 Python：请运行 ./scripts/prepare-runtime.sh 准备 runtime/python")
	}
	runner, err := pyRunnerPath()
	if err != nil {
		return "", err
	}

	startEpoch := s.epoch.Load()
	if err := s.startLocked(python, runner, script); err != nil {
		return "", err
	}
	if !s.inited && method != "init" {
		if _, err := s.callLocked(startEpoch, "init", map[string]interface{}{"extend": s.ext}); err != nil {
			s.stopLocked()
			return "", err
		}
		s.inited = true
	}
	out, err := s.callLocked(startEpoch, method, args)
	if err != nil {
		return "", err
	}
	if method == "init" {
		s.inited = true
	}
	return out, nil
}

func (s *pySpider) callLocked(startEpoch uint64, method string, args map[string]interface{}) (string, error) {
	reqID := s.nextID.Add(1)
	payload := map[string]interface{}{
		"id":       reqID,
		"method":   method,
		"args":     args,
		"clientId": hostclient.Current(),
	}
	body, err := json.Marshal(payload)
	if err != nil {
		return "", err
	}

	type exchangeResult struct {
		line string
		err  error
	}

	exchange := make(chan exchangeResult, 1)
	stdin, stdout := s.stdin, s.stdout
	go func() {
		if _, err := stdin.Write(append(body, '\n')); err != nil {
			exchange <- exchangeResult{err: err}
			return
		}
		for {
			line, err := stdout.ReadString('\n')
			if err != nil {
				exchange <- exchangeResult{err: err}
				return
			}
			line = strings.TrimSpace(line)
			if !strings.HasPrefix(line, "{") {
				if line != "" {
					log.Printf("[py:%s] 忽略非 JSON 输出: %s", s.key, line)
				}
				continue
			}
			var probe struct {
				ID *uint64 `json:"id"`
			}
			if json.Unmarshal([]byte(line), &probe) != nil || probe.ID == nil {
				log.Printf("[py:%s] 忽略无 id 的 JSON 输出: %s", s.key, truncatePyLog(line))
				continue
			}
			if *probe.ID != reqID {
				log.Printf("[py:%s] 忽略不匹配 id=%d (want %d)", s.key, *probe.ID, reqID)
				continue
			}
			exchange <- exchangeResult{line: line}
			return
		}
	}()

	select {
	case result := <-exchange:
		if s.epoch.Load() != startEpoch {
			s.stopLocked()
			return "", ErrScriptInterrupted
		}
		if result.err != nil {
			s.stopLocked()
			return "", fmt.Errorf("Python 进程异常: %w", result.err)
		}
		var response struct {
			ID     uint64          `json:"id"`
			OK     bool            `json:"ok"`
			Result json.RawMessage `json:"result"`
			Error  string          `json:"error"`
		}
		if err := json.Unmarshal([]byte(result.line), &response); err != nil {
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
	case <-time.After(pyCallTimeout):
		s.epoch.Add(1)
		if p := s.proc.Load(); p != nil {
			_ = p.Kill()
		}
		s.stopLocked()
		return "", fmt.Errorf("Python %s 调用超过 %s", method, pyCallTimeout)
	}
}

func pySitePackages(pythonExe string) []string {
	dir := filepath.Dir(pythonExe)
	cands := []string{
		filepath.Join(dir, "Lib", "site-packages"),
		filepath.Join(dir, "lib", "site-packages"),
	}
	parent := filepath.Dir(dir)
	cands = append(cands,
		filepath.Join(parent, "Lib", "site-packages"),
		filepath.Join(parent, "lib", "site-packages"),
	)
	var out []string
	for _, c := range cands {
		if st, err := os.Stat(c); err == nil && st.IsDir() {
			out = append(out, c)
		}
	}
	return out
}

func (s *pySpider) startLocked(python, runner, script string) error {
	if s.cmd != nil && s.cmd.Process != nil && s.cmd.ProcessState == nil {
		return nil
	}
	s.stopLocked()
	cmd := exec.Command(python, "-u", runner, script, s.key, s.ext, s.api, paths.PyCache())
	// 缓存目录 + 捆绑 site-packages（Windows embed 常忽略仅含 cache 的 PYTHONPATH）
	pyPathParts := append([]string{paths.PyCache()}, pySitePackages(python)...)
	cmd.Env = append(os.Environ(),
		"PYTHONUNBUFFERED=1",
		"PYTHONUTF8=1",
		"PYTHONIOENCODING=utf-8",
		"PYTHONPATH="+strings.Join(pyPathParts, string(os.PathListSeparator)),
		"KOTV_PY_CACHE="+paths.PyCache(),
		fmt.Sprintf("KOTV_PROXY_PORT=%d", localproxy.Port()),
	)
	setChildProcAttrs(cmd)
	stdin, err := cmd.StdinPipe()
	if err != nil {
		return err
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		_ = stdin.Close()
		return err
	}
	stderr, err := cmd.StderrPipe()
	if err != nil {
		_ = stdin.Close()
		return err
	}
	if err := cmd.Start(); err != nil {
		_ = stdin.Close()
		return err
	}
	s.cmd, s.stdin, s.stdout = cmd, stdin, bufio.NewReader(stdout)
	s.proc.Store(cmd.Process)
	go func() {
		scanner := bufio.NewScanner(stderr)
		for scanner.Scan() {
			log.Printf("[py:%s] %s", s.key, scanner.Text())
		}
	}()
	go func() { _ = cmd.Wait() }()
	return nil
}

func (s *pySpider) stopLocked() {
	if s.stdin != nil {
		_ = s.stdin.Close()
	}
	if p := s.proc.Swap(nil); p != nil {
		killProcessTree(p)
	}
	s.cmd, s.stdin, s.stdout = nil, nil, nil
	s.inited = false
}

func (s *pySpider) interrupt() {
	s.epoch.Add(1)
	s.mu.Lock()
	defer s.mu.Unlock()
	if goruntime.GOOS == "android" {
		// 清 Chaquopy 进程内 session，避免换源后复用旧 Spider
		client := &http.Client{Timeout: 2 * time.Second}
		req, err := http.NewRequest(http.MethodPost, "http://127.0.0.1:9979/py/interrupt", bytes.NewReader([]byte("{}")))
		if err == nil {
			resp, err := client.Do(req)
			if err == nil {
				_, _ = io.Copy(io.Discard, resp.Body)
				resp.Body.Close()
			}
		}
		s.inited = false
		return
	}
	if p := s.proc.Load(); p != nil {
		killProcessTree(p)
	}
	s.stopLocked()
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

func truncatePyLog(line string) string {
	if len(line) > 160 {
		return line[:160] + "..."
	}
	return line
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
		"key":        s.key,
		"ext":        s.ext,
		"api":        s.api,
		"cacheRoot":  paths.PyCache(),
		"proxyPort":  localproxy.Port(),
		"method":     method,
		"args":       args,
		"clientId":   hostclient.Current(),
		"slot":       s.sessionSlot,
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
	switch v := wrap.Result.(type) {
	case string:
		return strings.TrimSpace(v), nil
	default:
		return strings.TrimSpace(fmt.Sprint(v)), nil
	}
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
	if s.cmd != nil && s.inited {
		_, _ = s.callLocked(s.epoch.Load(), "destroy", map[string]interface{}{})
	}
	s.stopLocked()
	s.mu.Unlock()
	s.interrupt()
}
