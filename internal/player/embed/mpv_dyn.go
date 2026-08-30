//go:build cgo

package embed

/*
#cgo CFLAGS: -I${SRCDIR}
#cgo darwin LDFLAGS: -ldl
#cgo linux LDFLAGS: -ldl
#cgo windows LDFLAGS: -lkernel32

#include <stdint.h>
#include <stdlib.h>
#include "mpv_shim.h"

// 用 long long，避免 gopls 漏 include 时认不出 int64_t。
int kotv_mpv_set_hard_win(long long win);
*/
import "C"

import (
	"fmt"
	"image"
	"path/filepath"
	"sync"
	"unsafe"

	appruntime "github.com/bobo/KOTV/internal/runtime"
)

var (
	mpvMu       sync.Mutex
	mpvReady    bool
	mpvHard     bool
	mpvFrameBuf = make([]byte, 1920*1080*4)
)

func mpvProbe() bool {
	return appruntime.LibMPV() != ""
}

func mpvOpen() error {
	mpvMu.Lock()
	defer mpvMu.Unlock()
	if mpvReady {
		return nil
	}
	lib := appruntime.LibMPV()
	if lib == "" {
		return fmt.Errorf("未找到捆绑 libmpv：请将 mpv-2.dll / libmpv 与应用放在同目录")
	}
	prependPathEnv(filepath.Dir(lib))
	cPath := C.CString(lib)
	defer C.free(unsafe.Pointer(cPath))
	rc := int(C.kotv_mpv_load(cPath))
	if rc != 0 {
		return fmt.Errorf("加载 libmpv 失败(code=%d)：%s", rc, lib)
	}
	mpvReady = true
	mpvHard = false
	return nil
}

func mpvClose() {
	mpvMu.Lock()
	defer mpvMu.Unlock()
	if mpvReady {
		C.kotv_mpv_unload()
		mpvReady = false
		mpvHard = false
	}
}

func mpvPlay(url string) error {
	mpvMu.Lock()
	defer mpvMu.Unlock()
	if !mpvReady {
		return fmt.Errorf("libmpv 未初始化")
	}
	cURL := C.CString(url)
	defer C.free(unsafe.Pointer(cURL))
	if rc := int(C.kotv_mpv_play(cURL)); rc < 0 {
		return fmt.Errorf("MPV 播放失败(code=%d)", rc)
	}
	return nil
}

func mpvStop() {
	mpvMu.Lock()
	defer mpvMu.Unlock()
	if mpvReady {
		C.kotv_mpv_stop()
	}
}

func mpvPause(pause bool) {
	mpvMu.Lock()
	defer mpvMu.Unlock()
	if !mpvReady {
		return
	}
	var value C.int
	if pause {
		value = 1
	}
	C.kotv_mpv_pause(value)
}

func mpvIsPlaying() bool {
	mpvMu.Lock()
	defer mpvMu.Unlock()
	return mpvReady && C.kotv_mpv_is_playing() != 0
}

func mpvEofReached() bool {
	mpvMu.Lock()
	defer mpvMu.Unlock()
	return mpvReady && C.kotv_mpv_eof_reached() != 0
}

func mpvSetTime(ms int64) {
	mpvMu.Lock()
	defer mpvMu.Unlock()
	if mpvReady {
		C.kotv_mpv_set_time(C.int64_t(ms))
	}
}

func mpvGetTime() int64 {
	mpvMu.Lock()
	defer mpvMu.Unlock()
	if !mpvReady {
		return 0
	}
	return int64(C.kotv_mpv_get_time())
}

func mpvGetLength() int64 {
	mpvMu.Lock()
	defer mpvMu.Unlock()
	if !mpvReady {
		return 0
	}
	return int64(C.kotv_mpv_get_length())
}

func mpvSetVolume(volume int) {
	mpvMu.Lock()
	defer mpvMu.Unlock()
	if mpvReady {
		C.kotv_mpv_set_volume(C.int(volume))
	}
}

func mpvSetPropString(name, value string) bool {
	mpvMu.Lock()
	defer mpvMu.Unlock()
	if !mpvReady {
		return false
	}
	cName := C.CString(name)
	cValue := C.CString(value)
	defer C.free(unsafe.Pointer(cName))
	defer C.free(unsafe.Pointer(cValue))
	return C.kotv_mpv_set_prop_string(cName, cValue) >= 0
}

func mpvSetPropDouble(name string, value float64) bool {
	mpvMu.Lock()
	defer mpvMu.Unlock()
	if !mpvReady {
		return false
	}
	cName := C.CString(name)
	defer C.free(unsafe.Pointer(cName))
	return C.kotv_mpv_set_prop_double(cName, C.double(value)) >= 0
}

func mpvGetPropDouble(name string) (float64, bool) {
	mpvMu.Lock()
	defer mpvMu.Unlock()
	if !mpvReady {
		return 0, false
	}
	cName := C.CString(name)
	defer C.free(unsafe.Pointer(cName))
	var out C.double
	if C.kotv_mpv_get_prop_double(cName, &out) < 0 {
		return 0, false
	}
	return float64(out), true
}

func mpvGetPropInt64(name string) (int64, bool) {
	mpvMu.Lock()
	defer mpvMu.Unlock()
	if !mpvReady {
		return 0, false
	}
	cName := C.CString(name)
	defer C.free(unsafe.Pointer(cName))
	var out C.int64_t
	if C.kotv_mpv_get_prop_int64(cName, &out) < 0 {
		return 0, false
	}
	return int64(out), true
}

func mpvSetPropInt64(name string, value int64) bool {
	mpvMu.Lock()
	defer mpvMu.Unlock()
	if !mpvReady {
		return false
	}
	cName := C.CString(name)
	defer C.free(unsafe.Pointer(cName))
	return C.kotv_mpv_set_prop_int64(cName, C.int64_t(value)) >= 0
}

func mpvGetPropString(name string) (string, bool) {
	mpvMu.Lock()
	defer mpvMu.Unlock()
	if !mpvReady {
		return "", false
	}
	cName := C.CString(name)
	defer C.free(unsafe.Pointer(cName))
	out := C.kotv_mpv_get_prop_string(cName)
	if out == nil {
		return "", false
	}
	s := C.GoString(out)
	C.kotv_mpv_free_str(out)
	return s, true
}

func mpvCmd2(a, b string) bool {
	mpvMu.Lock()
	defer mpvMu.Unlock()
	if !mpvReady {
		return false
	}
	cA := C.CString(a)
	cB := C.CString(b)
	defer C.free(unsafe.Pointer(cA))
	defer C.free(unsafe.Pointer(cB))
	return C.kotv_mpv_cmd2(cA, cB) >= 0
}

func mpvCycle(prop string) bool {
	mpvMu.Lock()
	defer mpvMu.Unlock()
	if !mpvReady {
		return false
	}
	cProp := C.CString(prop)
	defer C.free(unsafe.Pointer(cProp))
	return C.kotv_mpv_cycle(cProp) >= 0
}

func mpvSnapshotRGBA() (*image.RGBA, bool) {
	mpvMu.Lock()
	defer mpvMu.Unlock()
	if !mpvReady || mpvHard || len(mpvFrameBuf) == 0 {
		return nil, false
	}
	var w, h C.int
	ok := C.kotv_mpv_take_frame(
		(*C.uint8_t)(unsafe.Pointer(&mpvFrameBuf[0])),
		C.int(len(mpvFrameBuf)),
		&w, &h,
	)
	if ok == 0 || w <= 0 || h <= 0 {
		return nil, false
	}
	iw, ih := int(w), int(h)
	need := iw * ih * 4
	if need > len(mpvFrameBuf) {
		return nil, false
	}
	img := image.NewRGBA(image.Rect(0, 0, iw, ih))
	copy(img.Pix, mpvFrameBuf[:need])
	return img, true
}

func mpvHardActive() bool {
	mpvMu.Lock()
	defer mpvMu.Unlock()
	return mpvReady && mpvHard
}

func mpvSetHardOutput(hwnd uintptr) error {
	mpvMu.Lock()
	defer mpvMu.Unlock()
	if !mpvReady {
		return fmt.Errorf("libmpv 未初始化")
	}
	rc := int(C.kotv_mpv_set_hard_win(C.longlong(hwnd)))
	if rc != 0 {
		return fmt.Errorf("MPV 切换输出失败(code=%d)", rc)
	}
	mpvHard = hwnd != 0
	return nil
}
