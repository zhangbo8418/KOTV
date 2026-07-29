package spider

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
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
		return androidCallJavaBridge(payload)
	}
	if !embedjvm.Active {
		return "", fmt.Errorf("嵌入 JVM 不可用：请以 CGO_ENABLED=1 构建")
	}
	if err := embedjvm.EnsureStarted(""); err != nil {
		return "", err
	}
	if err := primeNetConfigOnce(); err != nil {
		return "", err
	}
	out, err := embedjvm.Call(payload)
	if err != nil && errors.Is(err, embedjvm.ErrInterrupted) {
		return "", ErrJavaBridgeInterrupted
	}
	return out, err
}

func primeNetConfigOnce() error {
	netConfigMu.Lock()
	already := netPrimed
	netConfigMu.Unlock()
	if already {
		return nil
	}
	for _, cfg := range currentNetConfig() {
		if _, err := embedjvm.Call(cfg); err != nil {
			return fmt.Errorf("下发网络配置到嵌入 JVM 失败: %w", err)
		}
	}
	netConfigMu.Lock()
	netPrimed = true
	netConfigMu.Unlock()
	return nil
}

func pushBridgeIfAlive(payload []byte) {
	if runtime.GOOS == "android" {
		_, _ = androidCallJavaBridge(payload)
		return
	}
	if !embedjvm.Active {
		return
	}
	if err := embedjvm.EnsureStarted(""); err != nil {
		return
	}
	_, _ = embedjvm.Call(payload)
	netConfigMu.Lock()
	netPrimed = true
	netConfigMu.Unlock()
}

func androidCallJavaBridge(payload []byte) (string, error) {
	const base = "http://127.0.0.1:9979"
	req, err := http.NewRequest(http.MethodPost, base+"/jar/call", bytes.NewReader(payload))
	if err != nil {
		return "", err
	}
	req.Header.Set("Content-Type", "application/json; charset=utf-8")
	client := &http.Client{Timeout: 20 * time.Second}
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

// InterruptJavaBridge 打断卡住的 JAR 调用。
func InterruptJavaBridge() {
	netConfigMu.Lock()
	netPrimed = false
	netConfigMu.Unlock()
	if runtime.GOOS == "android" {
		return
	}
	embedjvm.Interrupt()
}
