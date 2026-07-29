//go:build cgo && !kotv_android

package embedjvm

/*
#cgo CFLAGS: -I${SRCDIR}/native -I${SRCDIR}/jni
#cgo darwin CFLAGS: -I${SRCDIR}/jni/darwin
#cgo linux CFLAGS: -I${SRCDIR}/jni/linux
#cgo windows CFLAGS: -I${SRCDIR}/jni/win32
#include <stdlib.h>
#include "bridge.h"
#include "bridge.c"
*/
import "C"
import (
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"sync/atomic"
	"unsafe"

	"github.com/bobo/KOTV/internal/localproxy"
	"github.com/bobo/KOTV/internal/paths"
	appruntime "github.com/bobo/KOTV/internal/runtime"
)

var (
	mu        sync.Mutex
	epoch     atomic.Uint64
	started   bool
)

// EnsureStarted 动态加载捆绑 libjvm 并 CreateJavaVM（classpath=spider-bridge.jar）。
func EnsureStarted(bridgeJar string) error {
	mu.Lock()
	defer mu.Unlock()
	if started {
		return nil
	}
	jvmLib := appruntime.JVMLib()
	if jvmLib == "" {
		return fmt.Errorf("未找到捆绑 libjvm：请运行 ./scripts/prepare-runtime.sh")
	}
	if bridgeJar == "" {
		bridgeJar = appruntime.BridgeJAR()
	}
	if bridgeJar == "" {
		return fmt.Errorf("未找到 spider-bridge.jar")
	}
	prependJVMLibraryPath(jvmLib)
	cacheDir := paths.Root()
	proxyPort := localproxy.Port()

	cJvm := C.CString(jvmLib)
	cJar := C.CString(bridgeJar)
	cCache := C.CString(cacheDir)
	defer C.free(unsafe.Pointer(cJvm))
	defer C.free(unsafe.Pointer(cJar))
	defer C.free(unsafe.Pointer(cCache))

	errbuf := make([]byte, 512)
	rc := C.kotv_jvm_start(cJvm, cJar, cCache, C.int(proxyPort), (*C.char)(unsafe.Pointer(&errbuf[0])), C.int(len(errbuf)))
	if rc != 0 {
		return fmt.Errorf("embed JVM 启动失败: %s", strings.TrimRight(string(errbuf), "\x00"))
	}
	started = true
	return nil
}

// Call 调用 SpiderBridge.call(JSON)。
func Call(payload []byte) (string, error) {
	mu.Lock()
	defer mu.Unlock()
	if !started {
		return "", fmt.Errorf("embed JVM 未启动")
	}
	startEpoch := epoch.Load()
	cIn := C.CString(string(payload))
	defer C.free(unsafe.Pointer(cIn))
	out := make([]byte, 2<<20)
	errbuf := make([]byte, 512)
	rc := C.kotv_jvm_call(cIn, (*C.char)(unsafe.Pointer(&out[0])), C.int(len(out)), (*C.char)(unsafe.Pointer(&errbuf[0])), C.int(len(errbuf)))
	if epoch.Load() != startEpoch {
		return "", ErrInterrupted
	}
	if rc != 0 {
		return "", fmt.Errorf("embed JVM 调用失败: %s", strings.TrimRight(string(errbuf), "\x00"))
	}
	return strings.TrimSpace(string(out)), nil
}

// Shutdown 销毁 JVM（换源打断 / 进程退出）。
func Shutdown() {
	mu.Lock()
	defer mu.Unlock()
	C.kotv_jvm_shutdown()
	started = false
	epoch.Add(1)
}

// Interrupt 打断：销毁 JVM，下次调用会重新 EnsureStarted。
func Interrupt() {
	Shutdown()
}

var ErrInterrupted = fmt.Errorf("JAR 调用已中断")

func prependJVMLibraryPath(jvmLib string) {
	jvmLib = filepath.Clean(jvmLib)
	serverDir := filepath.Dir(jvmLib)
	jreLib := filepath.Dir(serverDir)
	if runtime.GOOS == "windows" {
		bin := filepath.Join(filepath.Dir(jreLib), "bin")
		path := os.Getenv("PATH")
		if !strings.Contains(path, bin) {
			_ = os.Setenv("PATH", bin+string(os.PathListSeparator)+path)
		}
		return
	}
	// macOS / Linux：让动态加载器能找到 libjvm 依赖
	if runtime.GOOS == "darwin" {
		existing := os.Getenv("DYLD_LIBRARY_PATH")
		merged := serverDir + string(os.PathListSeparator) + jreLib
		if existing != "" {
			merged += string(os.PathListSeparator) + existing
		}
		_ = os.Setenv("DYLD_LIBRARY_PATH", merged)
	} else {
		existing := os.Getenv("LD_LIBRARY_PATH")
		merged := serverDir + string(os.PathListSeparator) + jreLib
		if existing != "" {
			merged += string(os.PathListSeparator) + existing
		}
		_ = os.Setenv("LD_LIBRARY_PATH", merged)
	}
}
