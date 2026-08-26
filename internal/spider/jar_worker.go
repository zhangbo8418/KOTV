package spider

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/bobo/KOTV/internal/hostclient"
	"github.com/bobo/KOTV/internal/localproxy"
	"github.com/bobo/KOTV/internal/paths"
	appruntime "github.com/bobo/KOTV/internal/runtime"
)

// ErrJavaBridgeInterrupted 表示调用被换源/关闭主动打断，不应再重试同一请求。
var ErrJavaBridgeInterrupted = errors.New("JAR 调用已中断")

// 桌面：独立 java -jar --serve（HTTP 多路）；超时后 Kill 并允许重建。
const javaBridgeCallTimeout = 120 * time.Second

type javaBridgeClient struct {
	mu         sync.Mutex
	cmd        *exec.Cmd
	baseURL    string // http://127.0.0.1:port
	stderrFile *os.File
	proc       atomic.Pointer[os.Process]
	epoch      atomic.Uint64
}

var javaBridge javaBridgeClient

// 远端已登录用户：每人独立 JVM；空 userId 走共享 javaBridge（本机）。
var (
	userBridgesMu sync.Mutex
	userBridges   = map[string]*javaBridgeClient{}
)

func bridgeForUser(userID string) *javaBridgeClient {
	userID = strings.TrimSpace(userID)
	if userID == "" {
		return &javaBridge
	}
	userBridgesMu.Lock()
	defer userBridgesMu.Unlock()
	if b, ok := userBridges[userID]; ok {
		return b
	}
	b := &javaBridgeClient{}
	userBridges[userID] = b
	return b
}

func bridgeForCurrent() *javaBridgeClient {
	// 脚本（jar 文件）全局共享；仅 RuntimeUserID 非空时用独立 JVM。
	return bridgeForUser(hostclient.RuntimeUserID())
}

// KillUserRuntime 杀掉指定用户的 JAR-JVM，并销毁其 Py/JS 池。
func KillUserRuntime(userID string) {
	userID = strings.TrimSpace(userID)
	if userID == "" {
		return
	}
	DestroyUserScripts(userID)
	clearJarForUser(userID)
	userBridgesMu.Lock()
	b := userBridges[userID]
	delete(userBridges, userID)
	userBridgesMu.Unlock()
	if b == nil {
		return
	}
	b.epoch.Add(1)
	b.mu.Lock()
	b.stopLocked()
	b.mu.Unlock()
}

// HostSpiderReady 远端主机爬虫面是否可用（安卓=本机 9979；桌面=捆绑 runtime 可用即可）。
func HostSpiderReady() (ok bool, errMsg string) {
	if runtime.GOOS == "android" {
		client := &http.Client{Timeout: 800 * time.Millisecond}
		resp, err := client.Get("http://127.0.0.1:9979/health")
		if err != nil {
			return false, "安卓 SpiderService(:9979) 不可达：请保持 App/前台服务运行"
		}
		_ = resp.Body.Close()
		if resp.StatusCode >= 400 {
			return false, fmt.Sprintf("安卓 SpiderService 异常: HTTP %d", resp.StatusCode)
		}
		return true, ""
	}
	return true, ""
}

// RestartUserRuntime 硬杀该用户运行时；下次调用会冷启动新 JVM。
func RestartUserRuntime(userID string) {
	KillUserRuntime(userID)
}

// RestartCallerRuntime 硬重启当前请求所属运行时：远端该用户的 JVM/Py/JS，或本机共享池。
// 取消 / 换源立刻调用，不在外层死等；慢站靠单次 JAR/JS/Py 调用超时。
func RestartCallerRuntime() {
	if uid := hostclient.RuntimeUserID(); uid != "" {
		RestartUserRuntime(uid)
		return
	}
	RestartSharedRuntime()
}

// 点播配置的网络参数（headers/proxy/hosts/doh），在每个新 worker 启动时重放。
var (
	netConfigMu       sync.Mutex
	netConfigJSON     []byte // 空 clientId 默认桶（兼容）
	netConfigByClient map[string][]byte
	userProxyJSON     []byte
	netPrimed         bool // Android HTTP 用
)

// 进行中的 JAR HTTP 调用，按 ScopeID 软取消（不杀 JVM）。
type jarInflight struct {
	id       uint64
	clientID string // 实为 ScopeID
	cancel   context.CancelFunc
}

var (
	jarInflightMu sync.Mutex
	jarInflightQ  = map[uint64]*jarInflight{}
	jarCallSeq    atomic.Uint64
)

func beginJarCall(clientID string) (context.Context, func()) {
	ctx, cancel := context.WithCancel(context.Background())
	id := jarCallSeq.Add(1)
	jarInflightMu.Lock()
	jarInflightQ[id] = &jarInflight{id: id, clientID: clientID, cancel: cancel}
	jarInflightMu.Unlock()
	return ctx, func() {
		cancel()
		jarInflightMu.Lock()
		delete(jarInflightQ, id)
		jarInflightMu.Unlock()
	}
}

func cancelJarCalls(clientID string) {
	jarInflightMu.Lock()
	defer jarInflightMu.Unlock()
	for _, g := range jarInflightQ {
		if clientID == "" || g.clientID == clientID {
			g.cancel()
		}
	}
}

// SetNetConfig 把点播配置里的 headers/proxy/hosts/doh 下发到 bridge OkHttp（按当前 ScopeID）。
// 各用户当前源可不同，故 net 按 Scope 分桶；空 Scope 写默认桶。
func SetNetConfig(headers, proxy, hosts, doh []byte) {
	cid := hostclient.ScopeID()
	args := map[string]json.RawMessage{}
	add := func(name string, raw []byte) {
		trimmed := strings.TrimSpace(string(raw))
		if trimmed == "" || trimmed == "null" {
			return
		}
		args[name] = json.RawMessage(raw)
	}
	add("headers", headers)
	add("proxy", proxy)
	add("hosts", hosts)
	add("doh", doh)
	if cid != "" {
		b, _ := json.Marshal(cid)
		args["clientId"] = b
	}

	req := map[string]interface{}{"method": "configNet", "args": args, "clientId": cid}
	payload, err := json.Marshal(req)
	if err != nil {
		return
	}
	netConfigMu.Lock()
	if netConfigByClient == nil {
		netConfigByClient = map[string][]byte{}
	}
	netConfigByClient[cid] = payload
	if cid == "" {
		netConfigJSON = payload
	}
	netPrimed = false
	netConfigMu.Unlock()
	pushBridgeIfAlive(payload)
}

// SetUserProxy 把 KOTV 用户代理设置下发到 bridge。
func SetUserProxy(spec string) {
	spec = strings.TrimSpace(spec)
	url := ""
	if !(spec == "" || spec == "false" || strings.HasPrefix(spec, "false#")) {
		if i := strings.Index(spec, "#"); i >= 0 {
			url = strings.TrimSpace(spec[i+1:])
		} else {
			url = spec
		}
	}
	req := map[string]interface{}{"method": "configProxy", "args": map[string]string{"url": url}}
	payload, err := json.Marshal(req)
	if err != nil {
		return
	}
	netConfigMu.Lock()
	userProxyJSON = payload
	netPrimed = false
	netConfigMu.Unlock()
	pushBridgeIfAlive(payload)
}

func currentNetConfig() [][]byte {
	netConfigMu.Lock()
	defer netConfigMu.Unlock()
	var out [][]byte
	seen := map[string]struct{}{}
	if len(netConfigJSON) > 0 {
		out = append(out, netConfigJSON)
		seen[string(netConfigJSON)] = struct{}{}
	}
	for _, payload := range netConfigByClient {
		if len(payload) == 0 {
			continue
		}
		key := string(payload)
		if _, ok := seen[key]; ok {
			continue
		}
		seen[key] = struct{}{}
		out = append(out, payload)
	}
	if len(userProxyJSON) > 0 {
		out = append(out, userProxyJSON)
	}
	return out
}

// callJavaBridge：桌面走独立 java HTTP bridge；Android 走 Native Service HTTP。可并发。
func callJavaBridge(payload []byte) (string, error) {
	cid := hostclient.ScopeID()
	ctx, end := beginJarCall(cid)
	defer end()
	ctx, cancel := context.WithTimeout(ctx, javaBridgeCallTimeout)
	defer cancel()

	if runtime.GOOS == "android" {
		if err := primeAndroidNetConfigOnce(); err != nil {
			return "", err
		}
		return androidPostJarCtx(ctx, payload)
	}
	return bridgeForCurrent().callCtx(ctx, payload)
}

// InterruptJavaBridgeForClient 按 clientId 软取消进行中的 JAR（OkHttp + HTTP 客户端），不杀 JVM。
// clientID 为空时取消全部进行中的调用，仍不杀进程。
func InterruptJavaBridgeForClient(clientID string) {
	cancelJarCalls(clientID)
	softCancelJavaBridge(clientID)
}

// RestartSharedRuntime 硬重启本机共享 JVM/Py/JS（不动远端各用户独立运行时，不删脚本磁盘缓存）。
func RestartSharedRuntime() {
	cancelJarCalls("")
	// 只软取消 + 杀掉共享 bridge，绝不碰 userBridges。
	softCancelSharedBridgeOnly()
	if runtime.GOOS == "android" {
		client := &http.Client{Timeout: 2 * time.Second}
		req, err := http.NewRequest(http.MethodPost, "http://127.0.0.1:9979/jar/interrupt", bytes.NewReader([]byte("{}")))
		if err == nil {
			req.Header.Set("Content-Type", "application/json")
			if resp, err := client.Do(req); err == nil {
				_ = resp.Body.Close()
			}
		}
	} else {
		javaBridge.epoch.Add(1)
		if p := javaBridge.proc.Load(); p != nil {
			killProcessTree(p)
		}
	}
	clearSharedJsPy()
	clearSharedJarSpiders()
}

func softCancelSharedBridgeOnly() {
	body, _ := json.Marshal(map[string]string{"clientId": ""})
	payload, _ := json.Marshal(map[string]interface{}{
		"method":   "cancelClient",
		"args":     map[string]string{"clientId": ""},
		"clientId": "",
	})
	if runtime.GOOS == "android" {
		_, _ = androidPostJarShort(payload)
		return
	}
	base := javaBridge.currentBaseURL()
	if base == "" {
		return
	}
	_ = postJarPath(base, "/jar/cancel", body, 2*time.Second)
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	_, _ = javaBridge.httpPostCtx(ctx, payload)
	cancel()
}

func clearSharedJarSpiders() {
	jarMu.Lock()
	for k := range jarSpiders {
		// 本机共享：RuntimeUserID 为空，cacheKey 以 "\x01" 开头
		if strings.HasPrefix(k, "\x01") {
			delete(jarSpiders, k)
		}
	}
	jarMu.Unlock()
}

// InterruptJavaBridge 硬杀本机共享 JVM（兼容旧调用）；等同 RestartSharedRuntime 的 JVM 部分但不清 Py/JS。
// 新代码请用 RestartSharedRuntime。
func InterruptJavaBridge() {
	RestartSharedRuntime()
}

func softCancelJavaBridge(clientID string) {
	body, _ := json.Marshal(map[string]string{"clientId": clientID})
	payload, _ := json.Marshal(map[string]interface{}{
		"method":   "cancelClient",
		"args":     map[string]string{"clientId": clientID},
		"clientId": clientID,
	})
	if runtime.GOOS == "android" {
		_, _ = androidPostJarShort(payload)
		return
	}
	targets := []*javaBridgeClient{&javaBridge}
	userBridgesMu.Lock()
	if rid := hostclient.RuntimeUserID(); rid != "" {
		if b := userBridges[rid]; b != nil {
			targets = []*javaBridgeClient{b}
		}
	} else if clientID == "" {
		for _, b := range userBridges {
			targets = append(targets, b)
		}
	}
	userBridgesMu.Unlock()
	for _, br := range targets {
		base := br.currentBaseURL()
		if base == "" {
			continue
		}
		_ = postJarPath(base, "/jar/cancel", body, 2*time.Second)
		ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
		_, _ = br.httpPostCtx(ctx, payload)
		cancel()
	}
}

// ShutdownJavaBridge 引擎退出时杀掉共享与所有用户 JVM。
func ShutdownJavaBridge() {
	if runtime.GOOS == "android" {
		return
	}
	javaBridge.epoch.Add(1)
	javaBridge.mu.Lock()
	javaBridge.stopLocked()
	javaBridge.mu.Unlock()
	userBridgesMu.Lock()
	all := make([]*javaBridgeClient, 0, len(userBridges))
	for id, b := range userBridges {
		all = append(all, b)
		delete(userBridges, id)
	}
	userBridgesMu.Unlock()
	for _, b := range all {
		b.epoch.Add(1)
		b.mu.Lock()
		b.stopLocked()
		b.mu.Unlock()
	}
}

// ClearJarBridgeOnSwitch 换站时清空 Go 侧 jar 缓存，并向 bridge 发 clear。
func ClearJarBridgeOnSwitch() {
	jarMu.Lock()
	jarSpiders = map[string]*jarSpider{}
	jarMu.Unlock()
	req := bridgeRequest{Method: "clear"}
	payload, err := json.Marshal(req)
	if err != nil {
		return
	}
	_, _ = callJavaBridge(payload)
}

func (w *javaBridgeClient) currentBaseURL() string {
	w.mu.Lock()
	defer w.mu.Unlock()
	return w.baseURL
}

func (w *javaBridgeClient) pushIfAlive(payload []byte) {
	base := w.currentBaseURL()
	if base == "" {
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	_, _ = w.httpPostCtx(ctx, payload)
}

func (w *javaBridgeClient) callCtx(ctx context.Context, payload []byte) (string, error) {
	startEpoch := w.epoch.Load()
	var transportErr error
	for attempt := 0; attempt < 2; attempt++ {
		if err := ctx.Err(); err != nil {
			return "", ErrJavaBridgeInterrupted
		}
		if w.epoch.Load() != startEpoch {
			return "", ErrJavaBridgeInterrupted
		}
		if err := w.ensureStarted(); err != nil {
			return "", err
		}
		out, err := w.httpPostCtx(ctx, payload)
		if err == nil {
			if w.epoch.Load() != startEpoch {
				return "", ErrJavaBridgeInterrupted
			}
			return out, nil
		}
		transportErr = err
		if errors.Is(err, context.Canceled) || errors.Is(err, context.DeadlineExceeded) {
			return "", ErrJavaBridgeInterrupted
		}
		if w.epoch.Load() != startEpoch {
			return "", ErrJavaBridgeInterrupted
		}
		// 传输失败：停掉并重试一次（重建 JVM）。
		w.mu.Lock()
		w.stopLocked()
		w.mu.Unlock()
	}
	return "", fmt.Errorf("Java bridge 异常退出，自动重启后仍不可用: %w", transportErr)
}

func (w *javaBridgeClient) ensureStarted() error {
	w.mu.Lock()
	defer w.mu.Unlock()
	return w.startLocked()
}

func (w *javaBridgeClient) httpPostCtx(ctx context.Context, payload []byte) (string, error) {
	w.mu.Lock()
	base := w.baseURL
	w.mu.Unlock()
	if base == "" {
		return "", fmt.Errorf("Java bridge 未就绪")
	}
	return postJarPathCtx(ctx, base, "/jar/call", payload)
}

func (w *javaBridgeClient) aliveLocked() bool {
	return w.cmd != nil && w.cmd.Process != nil && w.cmd.ProcessState == nil && w.baseURL != ""
}

func (w *javaBridgeClient) startLocked() error {
	if w.aliveLocked() {
		return nil
	}
	w.stopLocked()

	java, err := findJava()
	if err != nil {
		return err
	}
	bridgeJar := findBridgeJar()
	if bridgeJar == "" {
		return fmt.Errorf("未找到 spider-bridge.jar，请运行 bridge 目录下的构建脚本")
	}

	port, err := pickFreeLocalPort()
	if err != nil {
		return err
	}

	proxyPort := localproxy.Port()
	cmd := exec.Command(java,
		"-Djava.awt.headless=true",
		fmt.Sprintf("-Dkotv.cache.dir=%s", paths.Root()),
		fmt.Sprintf("-Dkotv.bridge.port=%d", port),
		"-Djava.net.useSystemProxies=false",
		"-DsocksProxyHost=",
		"-DsocksProxyPort=",
		"-Dhttp.proxyHost=",
		"-Dhttp.proxyPort=",
		"-Dhttps.proxyHost=",
		"-Dhttps.proxyPort=",
		"-Dftp.proxyHost=",
		"-Dftp.proxyPort=",
		fmt.Sprintf("-Dkotv.proxy.port=%d", proxyPort),
		"-Dsun.net.client.defaultConnectTimeout=8000",
		"-Dsun.net.client.defaultReadTimeout=10000",
		"-Dfile.encoding=UTF-8",
		"--add-opens=java.base/java.lang=ALL-UNNAMED",
		"--add-opens=java.base/java.util=ALL-UNNAMED",
		"-jar", bridgeJar,
		"--serve",
		fmt.Sprintf("--http-port=%d", port),
	)
	cmd.Dir = filepath.Dir(bridgeJar)
	cmd.Env = append(filterProxyEnv(os.Environ()), fmt.Sprintf("KOTV_PROXY_PORT=%d", proxyPort))
	_ = os.MkdirAll(paths.LogDir(), 0o755)
	stderrPath := filepath.Join(paths.LogDir(), "java-bridge.err.log")
	stderrFile, err := os.OpenFile(stderrPath, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
	if err == nil {
		cmd.Stderr = stderrFile
	} else {
		cmd.Stderr = os.Stderr
		stderrFile = nil
	}
	setChildProcAttrs(cmd)

	if err := cmd.Start(); err != nil {
		if stderrFile != nil {
			_ = stderrFile.Close()
		}
		return fmt.Errorf("启动 Java bridge 失败: %w", err)
	}

	base := fmt.Sprintf("http://127.0.0.1:%d", port)
	w.cmd = cmd
	w.baseURL = base
	w.stderrFile = stderrFile
	w.proc.Store(cmd.Process)
	log.Printf("java bridge started pid=%d jar=%s url=%s", cmd.Process.Pid, bridgeJar, base)

	if err := waitBridgeHealthy(base, 15*time.Second); err != nil {
		hint := readBridgeErrTail(stderrPath)
		w.stopLocked()
		if hint != "" {
			return fmt.Errorf("等待 Java bridge HTTP 就绪失败: %w（详见 %s：%s）", err, stderrPath, hint)
		}
		return fmt.Errorf("等待 Java bridge HTTP 就绪失败: %w（详见 %s）", err, stderrPath)
	}

	for _, cfg := range currentNetConfig() {
		ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		_, err := postJarPathCtx(ctx, base, "/jar/call", cfg)
		cancel()
		if err != nil {
			hint := readBridgeErrTail(stderrPath)
			w.stopLocked()
			if hint != "" {
				return fmt.Errorf("下发网络配置到 Java bridge 失败: %w（详见 %s：%s）", err, stderrPath, hint)
			}
			return fmt.Errorf("下发网络配置到 Java bridge 失败: %w（详见 %s）", err, stderrPath)
		}
	}
	return nil
}

func pickFreeLocalPort() (int, error) {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return 0, err
	}
	defer ln.Close()
	addr, ok := ln.Addr().(*net.TCPAddr)
	if !ok || addr.Port <= 0 {
		return 0, fmt.Errorf("无法分配本地端口")
	}
	return addr.Port, nil
}

func waitBridgeHealthy(base string, timeout time.Duration) error {
	deadline := time.Now().Add(timeout)
	client := &http.Client{Timeout: 500 * time.Millisecond}
	var last error
	for time.Now().Before(deadline) {
		resp, err := client.Get(base + "/health")
		if err == nil {
			_ = resp.Body.Close()
			if resp.StatusCode < 400 {
				return nil
			}
			last = fmt.Errorf("http %d", resp.StatusCode)
		} else {
			last = err
		}
		time.Sleep(100 * time.Millisecond)
	}
	if last == nil {
		last = fmt.Errorf("timeout")
	}
	return last
}

func readBridgeErrTail(path string) string {
	b, err := os.ReadFile(path)
	if err != nil || len(b) == 0 {
		return ""
	}
	s := strings.TrimSpace(string(b))
	if len(s) > 240 {
		s = s[len(s)-240:]
	}
	s = strings.ReplaceAll(s, "\n", " | ")
	return s
}

func (w *javaBridgeClient) stopLocked() {
	w.proc.Store(nil)
	w.baseURL = ""
	if w.cmd != nil {
		if w.cmd.Process != nil && w.cmd.ProcessState == nil {
			killProcessTree(w.cmd.Process)
		}
		_ = w.cmd.Wait()
	}
	if w.stderrFile != nil {
		_ = w.stderrFile.Close()
	}
	w.cmd = nil
	w.stderrFile = nil
}

func findJava() (string, error) {
	if p := appruntime.Java(); p != "" {
		return p, nil
	}
	return "", fmt.Errorf("未找到捆绑 Java：请运行 ./scripts/prepare-runtime.sh 准备 runtime/jre")
}

func filterProxyEnv(env []string) []string {
	out := make([]string, 0, len(env))
	for _, e := range env {
		el := strings.ToLower(e)
		if strings.HasPrefix(el, "http_proxy=") || strings.HasPrefix(el, "https_proxy=") ||
			strings.HasPrefix(el, "all_proxy=") || strings.HasPrefix(el, "socks") ||
			strings.HasPrefix(el, "java_tool_options=") {
			continue
		}
		out = append(out, e)
	}
	return out
}

func bytesTrimSpace(b []byte) []byte {
	return []byte(strings.TrimSpace(string(b)))
}

// trimCString 去掉残留的 \0（TrimSpace 不会去掉）。
func trimCString(s string) string {
	if i := strings.IndexByte(s, 0); i >= 0 {
		s = s[:i]
	}
	return strings.TrimSpace(s)
}

func pushBridgeIfAlive(payload []byte) {
	if runtime.GOOS == "android" {
		client := &http.Client{Timeout: 300 * time.Millisecond}
		resp, err := client.Get("http://127.0.0.1:9979/health")
		if err != nil {
			return
		}
		_ = resp.Body.Close()
		if resp.StatusCode >= 400 {
			return
		}
		_, _ = androidCallJavaBridgeShort(payload)
		netConfigMu.Lock()
		netPrimed = true
		netConfigMu.Unlock()
		return
	}
	bridgeForCurrent().pushIfAlive(payload)
}

func primeAndroidNetConfigOnce() error {
	netConfigMu.Lock()
	if netPrimed {
		netConfigMu.Unlock()
		return nil
	}
	// 必须包含当前 Scope 的配置：多用户/多客户端时 headers/hosts/doh 按 Scope 分桶，
	// 只重放默认桶会导致当前会话的 Referer/UA/DoH 丢失，站点请求被反爬拦成空页。
	cid := hostclient.ScopeID()
	cfgs := make([][]byte, 0, 3)
	push := func(b []byte) {
		if len(b) == 0 {
			return
		}
		for _, seen := range cfgs {
			if string(seen) == string(b) {
				return
			}
		}
		cfgs = append(cfgs, append([]byte(nil), b...))
	}
	push(netConfigJSON)
	if cid != "" && netConfigByClient != nil {
		push(netConfigByClient[cid])
	}
	push(userProxyJSON)
	netPrimed = true
	netConfigMu.Unlock()

	for _, cfg := range cfgs {
		if _, err := androidCallJavaBridge(cfg); err != nil {
			netConfigMu.Lock()
			netPrimed = false
			netConfigMu.Unlock()
			return fmt.Errorf("下发网络配置到 Android jar bridge 失败: %w", err)
		}
	}
	return nil
}

func androidCallJavaBridge(payload []byte) (string, error) {
	return androidPostJar(payload, 20*time.Second)
}

func androidCallJavaBridgeShort(payload []byte) (string, error) {
	return androidPostJarShort(payload)
}

func androidPostJarShort(payload []byte) (string, error) {
	return androidPostJar(payload, 2*time.Second)
}

func androidPostJar(payload []byte, timeout time.Duration) (string, error) {
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	return androidPostJarCtx(ctx, payload)
}

func androidPostJarCtx(ctx context.Context, payload []byte) (string, error) {
	return postJarPathCtx(ctx, "http://127.0.0.1:9979", "/jar/call", payload)
}

func postJarPath(base, path string, payload []byte, timeout time.Duration) error {
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	_, err := postJarPathCtx(ctx, base, path, payload)
	return err
}

func postJarPathCtx(ctx context.Context, base, path string, payload []byte) (string, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, strings.TrimRight(base, "/")+path, bytes.NewReader(payload))
	if err != nil {
		return "", err
	}
	req.Header.Set("Content-Type", "application/json; charset=utf-8")
	client := &http.Client{Timeout: javaBridgeCallTimeout}
	resp, err := client.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()

	b, _ := io.ReadAll(io.LimitReader(resp.Body, 2<<20))
	s := strings.TrimSpace(string(b))
	if resp.StatusCode >= 400 {
		return "", fmt.Errorf("jar call failed: http=%d %s", resp.StatusCode, s)
	}
	if path == "/jar/call" && s == "" {
		return "", fmt.Errorf("jar call empty response")
	}
	return s, nil
}
