package spider

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"runtime"
	"strings"
	"sync"
	"time"

	"github.com/bobo/KOTV/internal/spider/embedjvm"
)

// ErrJavaBridgeInterrupted 表示调用被换源/关闭主动打断。
var ErrJavaBridgeInterrupted = errors.New("JAR 调用已中断")

// 点播配置的网络参数（headers/proxy/hosts/doh），在嵌入 JVM 首次启动后重放。
var (
	netConfigMu   sync.Mutex
	netConfigJSON []byte
	userProxyJSON []byte
	netPrimed     bool
)

// SetNetConfig 把点播配置里的 headers/proxy/hosts/doh 下发到 bridge OkHttp。
// 仅缓存 + 热更新；禁止在此冷启 JVM（对齐旧 pushIfAlive，避免 boot 卡 Ready）。
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
	netPrimed = false // 配置变更后，下次 callJavaBridge 经 primeNetConfigOnce 重放
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
	if len(netConfigJSON) > 0 {
		out = append(out, netConfigJSON)
	}
	if len(userProxyJSON) > 0 {
		out = append(out, userProxyJSON)
	}
	return out
}

// callJavaBridge：桌面走进程内 JNI；Android 走 Native Service。
func callJavaBridge(payload []byte) (string, error) {
	if runtime.GOOS == "android" {
		if err := primeAndroidNetConfigOnce(); err != nil {
			return "", err
		}
		return androidCallJavaBridge(payload)
	}
	if !embedjvm.Active {
		return "", fmt.Errorf("嵌入 JVM 不可用：请以 CGO_ENABLED=1 构建")
	}
	if err := embedjvm.EnsureStarted(""); err != nil {
		log.Printf("embed JVM 启动失败: %v", err)
		return "", err
	}
	if err := primeNetConfigOnce(); err != nil {
		log.Printf("embed JVM netConfig 失败: %v", err)
		return "", err
	}
	out, err := embedjvm.Call(payload)
	if err != nil && errors.Is(err, embedjvm.ErrInterrupted) {
		return "", ErrJavaBridgeInterrupted
	}
	if err != nil {
		log.Printf("embed JVM 调用失败: %v", err)
	}
	return trimCString(out), err
}

// trimCString 去掉 C 缓冲区残留的 \0（TrimSpace 不会去掉）。
func trimCString(s string) string {
	if i := strings.IndexByte(s, 0); i >= 0 {
		s = s[:i]
	}
	return strings.TrimSpace(s)
}

func primeNetConfigOnce() error {
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
	// 先占位，避免并发 call 重复灌配置；失败再回滚。
	netPrimed = true
	netConfigMu.Unlock()

	for _, cfg := range cfgs {
		if _, err := embedjvm.Call(cfg); err != nil {
			netConfigMu.Lock()
			netPrimed = false
			netConfigMu.Unlock()
			return fmt.Errorf("下发网络配置到嵌入 JVM 失败: %w", err)
		}
	}
	return nil
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

func pushBridgeIfAlive(payload []byte) {
	if runtime.GOOS == "android" {
		// 9979 未就绪时绝不用 20s 同步 POST 堵 boot；仅短探活后热更新。
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
		return
	}
	if !embedjvm.Active || !embedjvm.Started() {
		return
	}
	if _, err := embedjvm.Call(payload); err != nil {
		return
	}
	netConfigMu.Lock()
	netPrimed = true
	netConfigMu.Unlock()
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

// InterruptJavaBridge 打断卡住的 JAR 调用（OkHttp.cancelAll + epoch）。
// 注意：绝不能 DestroyJavaVM——同进程重建 JVM 会挂死/失败，这是从子进程模型迁 embed 时的错误照搬。
func InterruptJavaBridge() {
	if runtime.GOOS == "android" {
		return
	}
	embedjvm.Interrupt()
}
