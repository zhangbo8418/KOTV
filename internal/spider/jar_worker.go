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
	"runtime"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/bobo/KOTV/internal/localproxy"
	"github.com/bobo/KOTV/internal/paths"
	appruntime "github.com/bobo/KOTV/internal/runtime"
)

// ErrJavaBridgeInterrupted 表示调用被换源/关闭主动打断，不应再重试同一请求。
var ErrJavaBridgeInterrupted = errors.New("JAR 调用已中断")

// 桌面：独立 java -jar --serve。超时后 Kill 并允许重建。
const javaBridgeCallTimeout = 120 * time.Second

type javaBridgeClient struct {
	mu         sync.Mutex
	cmd        *exec.Cmd
	stdin      io.WriteCloser
	stdout     *bufio.Reader
	stderrFile *os.File
	proc       atomic.Pointer[os.Process]
	epoch      atomic.Uint64
}

var javaBridge javaBridgeClient

// 点播配置的网络参数（headers/proxy/hosts/doh），在每个新 worker 启动时重放。
var (
	netConfigMu   sync.Mutex
	netConfigJSON []byte
	userProxyJSON []byte
	netPrimed     bool // Android HTTP 用
)

// SetNetConfig 把点播配置里的 headers/proxy/hosts/doh 下发到 bridge OkHttp。
func SetNetConfig(headers, proxy, hosts, doh []byte) {
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

	req := map[string]interface{}{"method": "configNet", "args": args}
	payload, err := json.Marshal(req)
	if err != nil {
		return
	}
	netConfigMu.Lock()
	netConfigJSON = payload
	netPrimed = false
	netConfigMu.Unlock()
	// 仅热更新已存活的 bridge；不在换源解析时冷启动 JVM。
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
	if len(netConfigJSON) > 0 {
		out = append(out, netConfigJSON)
	}
	if len(userProxyJSON) > 0 {
		out = append(out, userProxyJSON)
	}
	return out
}

// callJavaBridge：桌面走独立 java -jar --serve；Android 走 Native Service HTTP。
func callJavaBridge(payload []byte) (string, error) {
	if runtime.GOOS == "android" {
		if err := primeAndroidNetConfigOnce(); err != nil {
			return "", err
		}
		return androidCallJavaBridge(payload)
	}
	return javaBridge.call(payload)
}

// InterruptJavaBridge 打断卡住的 JAR：抬 epoch 并 Kill 独立 java 进程。
func InterruptJavaBridge() {
	if runtime.GOOS == "android" {
		return
	}
	javaBridge.epoch.Add(1)
	if p := javaBridge.proc.Load(); p != nil {
		_ = p.Kill()
	}
}

// ShutdownJavaBridge 引擎退出时杀掉独立 JVM。
func ShutdownJavaBridge() {
	if runtime.GOOS == "android" {
		return
	}
	javaBridge.epoch.Add(1)
	javaBridge.mu.Lock()
	defer javaBridge.mu.Unlock()
	javaBridge.stopLocked()
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

func (w *javaBridgeClient) pushIfAlive(payload []byte) {
	w.mu.Lock()
	defer w.mu.Unlock()
	if !w.aliveLocked() {
		return
	}
	_ = w.primeLocked(payload)
}

func (w *javaBridgeClient) call(payload []byte) (string, error) {
	w.mu.Lock()
	defer w.mu.Unlock()

	startEpoch := w.epoch.Load()
	var transportErr error
	for attempt := 0; attempt < 2; attempt++ {
		if w.epoch.Load() != startEpoch {
			w.stopLocked()
			return "", ErrJavaBridgeInterrupted
		}
		if err := w.startLocked(); err != nil {
			return "", err
		}

		exchange := make(chan string, 1)
		exchangeErr := make(chan error, 1)
		stdin, stdout := w.stdin, w.stdout
		req := append(append([]byte(nil), bytesTrimSpace(payload)...), '\n')
		go func() {
			if _, err := stdin.Write(req); err != nil {
				exchangeErr <- err
				return
			}
			line, err := stdout.ReadBytes('\n')
			if err != nil {
				exchangeErr <- err
				return
			}
			exchange <- strings.TrimSpace(string(line))
		}()

		select {
		case response := <-exchange:
			if w.epoch.Load() != startEpoch {
				w.stopLocked()
				return "", ErrJavaBridgeInterrupted
			}
			return response, nil
		case transportErr = <-exchangeErr:
			w.stopLocked()
			if w.epoch.Load() != startEpoch {
				return "", ErrJavaBridgeInterrupted
			}
			continue
		case <-time.After(javaBridgeCallTimeout):
			transportErr = fmt.Errorf("调用超过 %s", javaBridgeCallTimeout)
			if p := w.proc.Load(); p != nil {
				_ = p.Kill()
			}
			w.stopLocked()
			if w.epoch.Load() != startEpoch {
				return "", ErrJavaBridgeInterrupted
			}
			continue
		}
	}
	return "", fmt.Errorf("Java bridge 异常退出，自动重启后仍不可用: %w", transportErr)
}

func (w *javaBridgeClient) aliveLocked() bool {
	return w.cmd != nil && w.cmd.Process != nil && w.cmd.ProcessState == nil
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

	proxyPort := localproxy.Port()
	cmd := exec.Command(java,
		"-Djava.awt.headless=true",
		fmt.Sprintf("-Dkotv.cache.dir=%s", paths.Root()),
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
	setHiddenConsoleAttrs(cmd)

	stdin, err := cmd.StdinPipe()
	if err != nil {
		if stderrFile != nil {
			_ = stderrFile.Close()
		}
		return fmt.Errorf("创建 Java bridge 输入管道失败: %w", err)
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		_ = stdin.Close()
		if stderrFile != nil {
			_ = stderrFile.Close()
		}
		return fmt.Errorf("创建 Java bridge 输出管道失败: %w", err)
	}
	if err := cmd.Start(); err != nil {
		_ = stdin.Close()
		if stderrFile != nil {
			_ = stderrFile.Close()
		}
		return fmt.Errorf("启动 Java bridge 失败: %w", err)
	}

	w.cmd = cmd
	w.stdin = stdin
	w.stdout = bufio.NewReader(stdout)
	w.stderrFile = stderrFile
	w.proc.Store(cmd.Process)
	log.Printf("java bridge started pid=%d jar=%s", cmd.Process.Pid, bridgeJar)

	for _, cfg := range currentNetConfig() {
		if err := w.primeLocked(cfg); err != nil {
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

func (w *javaBridgeClient) primeLocked(payload []byte) error {
	req := append(append([]byte(nil), bytesTrimSpace(payload)...), '\n')
	if _, err := w.stdin.Write(req); err != nil {
		return err
	}
	if _, err := w.stdout.ReadBytes('\n'); err != nil {
		return err
	}
	return nil
}

func (w *javaBridgeClient) stopLocked() {
	w.proc.Store(nil)
	if w.stdin != nil {
		_ = w.stdin.Close()
	}
	if w.cmd != nil {
		if w.cmd.Process != nil && w.cmd.ProcessState == nil {
			_ = w.cmd.Process.Kill()
		}
		_ = w.cmd.Wait()
	}
	if w.stderrFile != nil {
		_ = w.stderrFile.Close()
	}
	w.cmd = nil
	w.stdin = nil
	w.stdout = nil
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
	javaBridge.pushIfAlive(payload)
}

func primeAndroidNetConfigOnce() error {
	netConfigMu.Lock()
	if netPrimed {
		netConfigMu.Unlock()
		return nil
	}
	cfgs := make([][]byte, 0, 2)
	if len(netConfigJSON) > 0 {
		cfgs = append(cfgs, append([]byte(nil), netConfigJSON...))
	}
	if len(userProxyJSON) > 0 {
		cfgs = append(cfgs, append([]byte(nil), userProxyJSON...))
	}
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
	return androidPostJar(payload, 2*time.Second)
}

func androidPostJar(payload []byte, timeout time.Duration) (string, error) {
	const base = "http://127.0.0.1:9979"
	req, err := http.NewRequest(http.MethodPost, base+"/jar/call", bytes.NewReader(payload))
	if err != nil {
		return "", err
	}
	req.Header.Set("Content-Type", "application/json; charset=utf-8")
	client := &http.Client{Timeout: timeout}
	resp, err := client.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()

	b, _ := io.ReadAll(io.LimitReader(resp.Body, 2<<20))
	s := strings.TrimSpace(string(b))
	if resp.StatusCode >= 400 {
		return "", fmt.Errorf("android jar call failed: http=%d %s", resp.StatusCode, s)
	}
	if s == "" {
		return "", fmt.Errorf("android jar call empty response")
	}
	return s, nil
}
