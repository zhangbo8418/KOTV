//go:build cgo && !kotv_android

package embedpy

/*
#cgo CFLAGS: -I${SRCDIR}/native
#include <stdlib.h>
// 用相对包路径，避免 gopls 未展开 ${SRCDIR} 时找不到 bridge.h 而丢掉 C 符号。
#include "native/bridge.h"
*/
import "C"
import (
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"time"
	"unsafe"

	"github.com/bobo/KOTV/internal/localproxy"
	"github.com/bobo/KOTV/internal/paths"
	appruntime "github.com/bobo/KOTV/internal/runtime"
)

const callTimeout = 45 * time.Second

type initMsg struct {
	lib, home string
	resp      chan error
}
type startMsg struct {
	boot string
	resp chan startResp
}
type startResp struct {
	sid uintptr
	err error
}
type callMsg struct {
	sid  uintptr
	line string
	resp chan callResp
}
type callResp struct {
	out string
	err error
}
type stopMsg struct {
	sid  uintptr
	done chan struct{}
}
type shutdownMsg struct {
	done chan struct{}
}

var (
	workerOnce sync.Once
	reqCh      chan any

	initMu  sync.Mutex
	inited  bool
	initErr error
)

func ensureWorker() {
	workerOnce.Do(func() {
		reqCh = make(chan any, 8)
		go func() {
			runtime.LockOSThread()
			for msg := range reqCh {
				switch m := msg.(type) {
				case initMsg:
					m.resp <- doInit(m.lib, m.home)
				case startMsg:
					m.resp <- doStart(m.boot)
				case callMsg:
					m.resp <- doCall(m.sid, m.line)
				case stopMsg:
					C.kotv_embedpy_stop((C.ulonglong)(m.sid))
					close(m.done)
				case shutdownMsg:
					C.kotv_embedpy_shutdown()
					close(m.done)
				}
			}
		}()
	})
}

func pythonHomeFromLib(lib string) string {
	home := filepath.Dir(lib)
	if strings.Contains(lib, string(filepath.Separator)+"lib"+string(filepath.Separator)) {
		home = filepath.Dir(home)
	}
	return home
}

func pythonHome() string {
	lib := appruntime.PythonLib()
	if lib == "" {
		return ""
	}
	return pythonHomeFromLib(lib)
}

func cString(b []byte) string {
	n := 0
	for n < len(b) && b[n] != 0 {
		n++
	}
	return strings.TrimSpace(string(b[:n]))
}

func doInit(lib, home string) error {
	cLib := C.CString(lib)
	cHome := C.CString(home)
	defer C.free(unsafe.Pointer(cLib))
	defer C.free(unsafe.Pointer(cHome))
	errbuf := make([]byte, 512)
	rc := C.kotv_embedpy_init(cLib, cHome, (*C.char)(unsafe.Pointer(&errbuf[0])), C.int(len(errbuf)))
	if rc != 0 {
		return fmt.Errorf("embed Python 初始化失败: %s", cString(errbuf))
	}
	return nil
}

func doStart(boot string) startResp {
	cBoot := C.CString(boot)
	defer C.free(unsafe.Pointer(cBoot))
	errbuf := make([]byte, 512)
	sid := C.kotv_embedpy_start(cBoot, (*C.char)(unsafe.Pointer(&errbuf[0])), C.int(len(errbuf)))
	if sid == 0 {
		return startResp{err: fmt.Errorf("embed Python session 启动失败: %s", cString(errbuf))}
	}
	return startResp{sid: uintptr(sid)}
}

func doCall(sid uintptr, line string) callResp {
	cLine := C.CString(line)
	defer C.free(unsafe.Pointer(cLine))
	out := make([]byte, 2<<20)
	errbuf := make([]byte, 512)
	rc := C.kotv_embedpy_call(
		(C.ulonglong)(sid),
		cLine,
		(*C.char)(unsafe.Pointer(&out[0])),
		C.int(len(out)),
		(*C.char)(unsafe.Pointer(&errbuf[0])),
		C.int(len(errbuf)),
	)
	if rc != 0 {
		return callResp{err: fmt.Errorf("embed Python 调用失败: %s", cString(errbuf))}
	}
	return callResp{out: cString(out)}
}

func ensureGlobal() error {
	initMu.Lock()
	defer initMu.Unlock()
	if inited {
		return initErr
	}
	ensureWorker()
	lib := appruntime.PythonLib()
	if lib == "" {
		initErr = fmt.Errorf("未找到捆绑 libpython：请运行 ./scripts/prepare-runtime.sh")
		inited = true
		return initErr
	}
	if abs, err := filepath.Abs(lib); err == nil {
		lib = abs
	}
	home := pythonHomeFromLib(lib)
	if runtime.GOOS == "windows" && home != "" {
		path := os.Getenv("PATH")
		if !strings.Contains(path, home) {
			_ = os.Setenv("PATH", home+string(os.PathListSeparator)+path)
		}
	}
	resp := make(chan error, 1)
	reqCh <- initMsg{lib: lib, home: home, resp: resp}
	initErr = <-resp
	inited = true
	return initErr
}

func sanitizePyIdent(s string) string {
	var b strings.Builder
	for _, r := range s {
		if (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') || (r >= '0' && r <= '9') || r == '_' {
			b.WriteRune(r)
		} else {
			b.WriteByte('_')
		}
	}
	if b.Len() == 0 {
		return "site"
	}
	return b.String()
}

func await[T any](ch <-chan T, timeout time.Duration, what string) (T, error) {
	var zero T
	select {
	case v := <-ch:
		return v, nil
	case <-time.After(timeout):
		return zero, fmt.Errorf("embed Python %s 超时（%s）", what, timeout)
	}
}

// StartSession 加载 pyrunner + 站点脚本，返回会话 id。
func StartSession(runner, script, key, ext, api, cache string) (uintptr, error) {
	if err := ensureGlobal(); err != nil {
		return 0, err
	}
	home := pythonHome()
	bootstrap := fmt.Sprintf(`import os, sys, importlib.util
os.environ['KOTV_PROXY_PORT'] = %q
os.environ['KOTV_PY_CACHE'] = %q
os.environ['PYTHONHOME'] = %q
os.environ['KOTV_PYTHON_HOME'] = %q
sys.argv = [%q, %q, %q, %q, %q, %q]
spec = importlib.util.spec_from_file_location('kotv_runner_%s', %q)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
__ref__ = mod.kotv_dispatch_json
`,
		fmt.Sprintf("%d", localproxy.Port()),
		cache,
		home,
		home,
		"pyrunner.py", script, key, ext, api, cache,
		sanitizePyIdent(key),
		runner,
	)
	resp := make(chan startResp, 1)
	reqCh <- startMsg{boot: bootstrap, resp: resp}
	// 启动含依赖预拉，给足时间，但必须有上限（旧子进程可 Kill；embed 只能超时返回）。
	r, err := await(resp, 90*time.Second, "session 启动")
	if err != nil {
		return 0, err
	}
	return r.sid, r.err
}

func CallSession(sid uintptr, jsonLine string) (string, error) {
	if sid == 0 {
		return "", fmt.Errorf("embed Python session 无效")
	}
	ensureWorker()
	resp := make(chan callResp, 1)
	reqCh <- callMsg{sid: sid, line: jsonLine, resp: resp}
	r, err := await(resp, callTimeout, "调用")
	if err != nil {
		return "", err
	}
	return r.out, r.err
}

func StopSession(sid uintptr) {
	if sid == 0 {
		return
	}
	ensureWorker()
	done := make(chan struct{})
	reqCh <- stopMsg{sid: sid, done: done}
	select {
	case <-done:
	case <-time.After(5 * time.Second):
	}
}

func Shutdown() {
	ensureWorker()
	done := make(chan struct{})
	reqCh <- shutdownMsg{done: done}
	select {
	case <-done:
	case <-time.After(5 * time.Second):
	}
	initMu.Lock()
	inited = false
	initErr = nil
	initMu.Unlock()
}

// DefaultCache returns py cache dir for embed bootstrap.
func DefaultCache() string { return paths.PyCache() }
