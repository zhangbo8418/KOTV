//go:build cgo && !kotv_android

package embedjvm

/*
#cgo CFLAGS: -I${SRCDIR}/native -I${SRCDIR}/jni
#cgo darwin CFLAGS: -I${SRCDIR}/jni/darwin
#cgo linux CFLAGS: -I${SRCDIR}/jni/linux
#cgo windows CFLAGS: -I${SRCDIR}/jni/win32
#include <stdlib.h>
// 用相对包路径，避免 gopls 未展开 ${SRCDIR} 时找不到 bridge.h 而丢掉 C 符号。
#include "native/bridge.h"
*/
import "C"
import (
	"fmt"
	"log"
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

// ErrInterrupted 表示调用被换源/关闭主动打断。
var ErrInterrupted = fmt.Errorf("JAR 调用已中断")

type startReq struct {
	jvmLib, bridgeJar, cacheDir string
	proxyPort                   int
	resp                        chan error
}

type callReq struct {
	payload []byte
	resp    chan callResp
}

type callResp struct {
	out string
	err error
}

type shutdownReq struct {
	done chan struct{}
}

var (
	workerOnce sync.Once
	reqCh      chan any
	epoch      atomic.Uint64
	started    atomic.Bool
)

func ensureWorker() {
	workerOnce.Do(func() {
		reqCh = make(chan any, 8)
		go func() {
			// JNIEnv / CreateJavaVM 必须钉在同一条 OS 线程；Go 调度迁移会直接挂死。
			runtime.LockOSThread()
			for msg := range reqCh {
				switch r := msg.(type) {
				case startReq:
					r.resp <- doStart(r)
				case callReq:
					r.resp <- doCall(r.payload)
				case shutdownReq:
					doShutdown()
					close(r.done)
				}
			}
		}()
	})
}

func doStart(r startReq) error {
	if started.Load() {
		return nil
	}
	log.Printf("embed JVM CreateJavaVM jvm=%s bridge=%s cache=%s", r.jvmLib, r.bridgeJar, r.cacheDir)
	cJvm := C.CString(r.jvmLib)
	cJar := C.CString(r.bridgeJar)
	cCache := C.CString(r.cacheDir)
	defer C.free(unsafe.Pointer(cJvm))
	defer C.free(unsafe.Pointer(cJar))
	defer C.free(unsafe.Pointer(cCache))

	errbuf := make([]byte, 512)
	rc := C.kotv_jvm_start(cJvm, cJar, cCache, C.int(r.proxyPort), (*C.char)(unsafe.Pointer(&errbuf[0])), C.int(len(errbuf)))
	if rc != 0 {
		err := fmt.Errorf("embed JVM 启动失败: %s", strings.TrimRight(string(errbuf), "\x00"))
		log.Printf("%v", err)
		return err
	}
	started.Store(true)
	log.Printf("embed JVM ready")
	return nil
}

func doCall(payload []byte) callResp {
	if !started.Load() {
		return callResp{err: fmt.Errorf("embed JVM 未启动")}
	}
	startEpoch := epoch.Load()
	cIn := C.CString(string(payload))
	defer C.free(unsafe.Pointer(cIn))
	out := make([]byte, 2<<20)
	errbuf := make([]byte, 512)
	rc := C.kotv_jvm_call(cIn, (*C.char)(unsafe.Pointer(&out[0])), C.int(len(out)), (*C.char)(unsafe.Pointer(&errbuf[0])), C.int(len(errbuf)))
	if epoch.Load() != startEpoch {
		return callResp{err: ErrInterrupted}
	}
	if rc != 0 {
		return callResp{err: fmt.Errorf("embed JVM 调用失败: %s", cString(errbuf))}
	}
	return callResp{out: cString(out)}
}

func doShutdown() {
	if !started.Load() {
		return
	}
	C.kotv_jvm_shutdown()
	started.Store(false)
	epoch.Add(1)
}

// cString 把 C 风格缓冲区裁到第一个 \0（整段 string(out) 会带上百万 null，JSON 报 invalid character '\x00'）。
func cString(b []byte) string {
	n := 0
	for n < len(b) && b[n] != 0 {
		n++
	}
	return strings.TrimSpace(string(b[:n]))
}

// EnsureStarted 动态加载捆绑 libjvm 并 CreateJavaVM（classpath=spider-bridge.jar）。
func EnsureStarted(bridgeJar string) error {
	ensureWorker()
	if started.Load() {
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
	resp := make(chan error, 1)
	reqCh <- startReq{
		jvmLib:    jvmLib,
		bridgeJar: bridgeJar,
		cacheDir:  paths.Root(),
		proxyPort: localproxy.Port(),
		resp:      resp,
	}
	return <-resp
}

// Call 调用 SpiderBridge.call(JSON)。所有 JNI 走专用 OS 线程。
func Call(payload []byte) (string, error) {
	ensureWorker()
	if !started.Load() {
		return "", fmt.Errorf("embed JVM 未启动")
	}
	resp := make(chan callResp, 1)
	reqCh <- callReq{payload: payload, resp: resp}
	r := <-resp
	return r.out, r.err
}

// Shutdown 仅进程退出时销毁 JVM（同进程内 Destroy 后再 Create 不可靠）。
func Shutdown() {
	ensureWorker()
	done := make(chan struct{})
	reqCh <- shutdownReq{done: done}
	<-done
}

// Interrupt 同步打断：抬 epoch，并 Attach 后触发 OkHttp.cancelAll。
// 不经 worker 队列，避免与卡住的 Call 死锁式互等；绝不 DestroyJavaVM。
func Interrupt() {
	epoch.Add(1)
	if !started.Load() {
		return
	}
	errbuf := make([]byte, 256)
	_ = C.kotv_jvm_cancel_all((*C.char)(unsafe.Pointer(&errbuf[0])), C.int(len(errbuf)))
}

// Started 报告嵌入 JVM 是否已 CreateJavaVM（不触发冷启）。
func Started() bool { return started.Load() }

func prependJVMLibraryPath(jvmLib string) {
	jvmLib = filepath.Clean(jvmLib)
	serverDir := filepath.Dir(jvmLib) // .../jre/bin/server
	binDir := filepath.Dir(serverDir) // .../jre/bin
	jreHome := filepath.Dir(binDir)   // .../jre
	if runtime.GOOS == "windows" {
		_ = os.Setenv("JAVA_HOME", jreHome)
		path := os.Getenv("PATH")
		prefix := binDir + string(os.PathListSeparator) + serverDir
		if !strings.Contains(path, binDir) {
			_ = os.Setenv("PATH", prefix+string(os.PathListSeparator)+path)
		}
		return
	}
	if runtime.GOOS == "darwin" {
		existing := os.Getenv("DYLD_LIBRARY_PATH")
		merged := serverDir + string(os.PathListSeparator) + binDir
		if existing != "" {
			merged += string(os.PathListSeparator) + existing
		}
		_ = os.Setenv("DYLD_LIBRARY_PATH", merged)
	} else {
		existing := os.Getenv("LD_LIBRARY_PATH")
		merged := serverDir + string(os.PathListSeparator) + binDir
		if existing != "" {
			merged += string(os.PathListSeparator) + existing
		}
		_ = os.Setenv("LD_LIBRARY_PATH", merged)
	}
}
