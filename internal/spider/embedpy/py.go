//go:build cgo && !kotv_android

package embedpy

/*
#cgo CFLAGS: -I${SRCDIR}/native
#include <stdlib.h>
#include "bridge.h"
#include "bridge.c"
*/
import "C"
import (
	"fmt"
	"path/filepath"
	"strings"
	"sync"
	"unsafe"

	"github.com/bobo/KOTV/internal/localproxy"
	"github.com/bobo/KOTV/internal/paths"
	appruntime "github.com/bobo/KOTV/internal/runtime"
)

var (
	initMu  sync.Mutex
	inited  bool
	initErr error
)

func ensureGlobal() error {
	initMu.Lock()
	defer initMu.Unlock()
	if inited {
		return initErr
	}
	lib := appruntime.PythonLib()
	if lib == "" {
		initErr = fmt.Errorf("未找到捆绑 libpython：请运行 ./scripts/prepare-runtime.sh")
		inited = true
		return initErr
	}
	home := filepath.Dir(lib)
	if strings.Contains(lib, string(filepath.Separator)+"lib"+string(filepath.Separator)) {
		home = filepath.Dir(home)
	}
	cLib := C.CString(lib)
	cHome := C.CString(home)
	defer C.free(unsafe.Pointer(cLib))
	defer C.free(unsafe.Pointer(cHome))

	errbuf := make([]byte, 512)
	rc := C.kotv_embedpy_init(cLib, cHome, (*C.char)(unsafe.Pointer(&errbuf[0])), C.int(len(errbuf)))
	if rc != 0 {
		initErr = fmt.Errorf("embed Python 初始化失败: %s", strings.TrimRight(string(errbuf), "\x00"))
	}
	inited = true
	return initErr
}

// StartSession 加载 pyrunner + 站点脚本，返回会话 id。
func StartSession(runner, script, key, ext, api, cache string) (uintptr, error) {
	if err := ensureGlobal(); err != nil {
		return 0, err
	}
	bootstrap := fmt.Sprintf(`import os, sys, importlib.util
os.environ['KOTV_PROXY_PORT'] = %q
os.environ['KOTV_PY_CACHE'] = %q
sys.argv = [%q, %q, %q, %q, %q, %q]
spec = importlib.util.spec_from_file_location('kotv_runner', %q)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
__ref__ = mod.kotv_dispatch_json
`,
		fmt.Sprintf("%d", localproxy.Port()),
		cache,
		"pyrunner.py", runner, key, ext, api, cache,
		runner,
	)
	cBoot := C.CString(bootstrap)
	defer C.free(unsafe.Pointer(cBoot))
	errbuf := make([]byte, 512)
	sid := C.kotv_embedpy_start(cBoot, (*C.char)(unsafe.Pointer(&errbuf[0])), C.int(len(errbuf)))
	if sid == 0 {
		return 0, fmt.Errorf("embed Python session 启动失败: %s", strings.TrimRight(string(errbuf), "\x00"))
	}
	return uintptr(sid), nil
}

func CallSession(sid uintptr, jsonLine string) (string, error) {
	cLine := C.CString(jsonLine)
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
		return "", fmt.Errorf("embed Python 调用失败: %s", strings.TrimRight(string(errbuf), "\x00"))
	}
	n := 0
	for n < len(out) && out[n] != 0 {
		n++
	}
	return strings.TrimSpace(string(out[:n])), nil
}

func StopSession(sid uintptr) {
	if sid == 0 {
		return
	}
	C.kotv_embedpy_stop((C.ulonglong)(sid))
}

func Shutdown() {
	initMu.Lock()
	defer initMu.Unlock()
	C.kotv_embedpy_shutdown()
	inited = false
	initErr = nil
}

// DefaultCache returns py cache dir for embed bootstrap.
func DefaultCache() string { return paths.PyCache() }
