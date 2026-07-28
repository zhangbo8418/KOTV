package spider

import (
	"bufio"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/bobo/KOTV/internal/localproxy"
	"github.com/bobo/KOTV/internal/paths"
	appruntime "github.com/bobo/KOTV/internal/runtime"
)

// 无效源网络超时不应拖死换源；超时后立刻杀掉 bridge，让有效源马上重试。
const javaBridgeCallTimeout = 12 * time.Second

// ErrJavaBridgeInterrupted 表示调用被换源/关闭主动打断，不应再重试同一请求。
var ErrJavaBridgeInterrupted = errors.New("JAR 调用已中断")

type javaBridgeClient struct {
	mu     sync.Mutex
	cmd    *exec.Cmd
	stdin  io.WriteCloser
	stdout *bufio.Reader
	proc   atomic.Pointer[os.Process]
	epoch  atomic.Uint64
}

var javaBridge javaBridgeClient

// 点播配置的网络参数（headers/proxy/hosts/doh），在每个新 worker 启动时重放，
// 把配置灌入 OkHttp 拦截器/选择器/DNS 的行为。
var (
	netConfigMu   sync.Mutex
	netConfigJSON []byte
	userProxyJSON []byte
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
	netConfigMu.Unlock()
	// 立即推给当前存活的 worker（若不存活会随下次启动重放）。
	_, _ = callJavaBridge(payload)
}

// SetUserProxy 把 KOTV 用户代理设置下发到 bridge，令 JAR 请求在未命中配置 proxy 规则时也走用户代理。
// spec 为设置里的原始值（如 "false#" 或 "true#http://127.0.0.1:7890"）。
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
	netConfigMu.Unlock()
	_, _ = callJavaBridge(payload)
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

// callJavaBridge 通过常驻捆绑 Java 进程调用 spider-bridge（JVM 只启动一次）。
func callJavaBridge(payload []byte) (string, error) {
	return javaBridge.call(payload)
}

// InterruptJavaBridge 打断卡住的 JAR 调用，并作废当前请求的自动重试。
func InterruptJavaBridge() {
	javaBridge.epoch.Add(1)
	if p := javaBridge.proc.Load(); p != nil {
		_ = p.Kill()
	}
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
		"-jar", bridgeJar,
		"--serve",
	)
	cmd.Dir = filepath.Dir(bridgeJar)
	cmd.Env = append(filterProxyEnv(os.Environ()), fmt.Sprintf("KOTV_PROXY_PORT=%d", proxyPort))
	cmd.Stderr = os.Stderr
	setHiddenConsoleAttrs(cmd)

	stdin, err := cmd.StdinPipe()
	if err != nil {
		return fmt.Errorf("创建 Java bridge 输入管道失败: %w", err)
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		_ = stdin.Close()
		return fmt.Errorf("创建 Java bridge 输出管道失败: %w", err)
	}
	if err := cmd.Start(); err != nil {
		_ = stdin.Close()
		return fmt.Errorf("启动 Java bridge 失败: %w", err)
	}

	w.cmd = cmd
	w.stdin = stdin
	w.stdout = bufio.NewReader(stdout)
	w.proc.Store(cmd.Process)

	// 新 worker 启动后重放点播网络配置与用户代理，重启进程也会重新灌入 OkHttp。
	for _, cfg := range currentNetConfig() {
		if err := w.primeLocked(cfg); err != nil {
			w.stopLocked()
			return fmt.Errorf("下发网络配置到 Java bridge 失败: %w", err)
		}
	}
	return nil
}

// primeLocked 在启动新进程后同步下发一次配置请求（configNet 只做内存写入，返回极快）。
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
	w.cmd = nil
	w.stdin = nil
	w.stdout = nil
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
