//go:build cgo

package embed

/*
#cgo CFLAGS: -I${SRCDIR}
#cgo darwin LDFLAGS: -ldl
#cgo linux LDFLAGS: -ldl
#cgo windows LDFLAGS: -lkernel32

#include <stdint.h>
#include <stdlib.h>
#include "vlc_shim.h"
#include "vlc_decode.h"

// 用 long long，避免 gopls 漏 include 时认不出 int64_t。
int kotv_vlc_set_hard_win(long long win);
int kotv_vlc_can_hard_output(void);
*/
import "C"

import (
	"fmt"
	"image"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"unsafe"

	appruntime "github.com/bobo/KOTV/internal/runtime"
)

var (
	vlcMu     sync.Mutex
	vlcReady  bool
	vlcHard   bool
	frameBuf  []byte
	frameOnce sync.Once
)

func vlcProbe() bool {
	libDir, pluginDir := resolveVLCDirs()
	if libDir == "" {
		return false
	}
	_ = pluginDir
	switch runtime.GOOS {
	case "darwin":
		return fileExists(filepath.Join(libDir, "libvlc.dylib")) ||
			fileExists(filepath.Join(libDir, "libvlc.5.dylib"))
	case "windows":
		return fileExists(filepath.Join(libDir, "libvlc.dll"))
	default:
		return fileExists(filepath.Join(libDir, "libvlc.so")) ||
			fileExists(filepath.Join(libDir, "libvlc.so.5"))
	}
}

func resolveVLCDirs() (libDir, pluginDir string) {
	// 优先 runtime/libvlc/（与 libmpv/ 对称，仅保留 lib + plugins）
	for _, root := range appruntime.Roots() {
		cands := []struct{ lib, plug string }{
			{filepath.Join(root, "libvlc"), filepath.Join(root, "libvlc", "plugins")},
			// 旧布局兼容
			{filepath.Join(root, "vlc", "VLC.app", "Contents", "MacOS", "lib"),
				filepath.Join(root, "vlc", "VLC.app", "Contents", "MacOS", "plugins")},
			{filepath.Join(root, "vlc"), filepath.Join(root, "vlc", "plugins")},
			{filepath.Join(root, "lib"), filepath.Join(root, "lib", "plugins")},
		}
		for _, c := range cands {
			if dirHasLibVLC(c.lib) {
				return c.lib, c.plug
			}
		}
	}

	bin := appruntime.VLC()
	if bin == "" {
		return "", ""
	}

	// macOS: .../VLC.app/Contents/MacOS/VLC
	if runtime.GOOS == "darwin" {
		macos := filepath.Dir(bin) // MacOS
		lib := filepath.Join(macos, "lib")
		plug := filepath.Join(macos, "plugins")
		if dirHasLibVLC(lib) {
			return lib, plug
		}
	}

	// Windows / 便携：exe 同目录即 libvlc.dll
	dir := filepath.Dir(bin)
	if dirHasLibVLC(dir) {
		return dir, filepath.Join(dir, "plugins")
	}
	lib := filepath.Join(dir, "lib")
	if dirHasLibVLC(lib) {
		return lib, filepath.Join(dir, "plugins")
	}
	return "", ""
}

func dirHasLibVLC(dir string) bool {
	if dir == "" {
		return false
	}
	switch runtime.GOOS {
	case "darwin":
		return fileExists(filepath.Join(dir, "libvlc.dylib")) ||
			fileExists(filepath.Join(dir, "libvlc.5.dylib"))
	case "windows":
		return fileExists(filepath.Join(dir, "libvlc.dll"))
	default:
		return fileExists(filepath.Join(dir, "libvlc.so")) ||
			fileExists(filepath.Join(dir, "libvlc.so.5")) ||
			fileExists(filepath.Join(dir, "libvlc.so.5.6.0"))
	}
}

func fileExists(p string) bool {
	st, err := os.Stat(p)
	return err == nil && !st.IsDir()
}

func vlcOpen() error {
	vlcMu.Lock()
	defer vlcMu.Unlock()
	if vlcReady {
		return nil
	}
	libDir, pluginDir := resolveVLCDirs()
	if libDir == "" {
		return fmt.Errorf("未找到捆绑 libvlc：请运行 ./scripts/prepare-runtime.sh 准备 runtime/libvlc")
	}
	// 帮助加载依赖 dylib/dll
	prependPathEnv(libDir)

	cLib := C.CString(libDir)
	cPlug := C.CString(pluginDir)
	defer C.free(unsafe.Pointer(cLib))
	defer C.free(unsafe.Pointer(cPlug))

	rc := int(C.kotv_vlc_load(cLib, cPlug))
	if rc != 0 {
		return fmt.Errorf("加载 libvlc 失败(code=%d)，目录=%s", rc, libDir)
	}
	vlcReady = true
	vlcHard = false
	return nil
}

func prependPathEnv(dir string) {
	switch runtime.GOOS {
	case "windows":
		key := "PATH"
		cur := os.Getenv(key)
		_ = os.Setenv(key, dir+string(os.PathListSeparator)+cur)
	case "darwin":
		key := "DYLD_LIBRARY_PATH"
		cur := os.Getenv(key)
		_ = os.Setenv(key, dir+string(os.PathListSeparator)+cur)
	default:
		key := "LD_LIBRARY_PATH"
		cur := os.Getenv(key)
		_ = os.Setenv(key, dir+string(os.PathListSeparator)+cur)
	}
}

func vlcClose() {
	vlcMu.Lock()
	defer vlcMu.Unlock()
	if !vlcReady {
		return
	}
	C.kotv_vlc_unload()
	vlcReady = false
	vlcHard = false
}

func vlcPlay(url string) error {
	vlcMu.Lock()
	defer vlcMu.Unlock()
	if !vlcReady {
		return fmt.Errorf("libvlc 未初始化")
	}
	cURL := C.CString(url)
	defer C.free(unsafe.Pointer(cURL))
	rc := int(C.kotv_vlc_play(cURL))
	if rc != 0 {
		return fmt.Errorf("VLC 播放失败(code=%d)", rc)
	}
	return nil
}

func vlcStop() {
	vlcMu.Lock()
	defer vlcMu.Unlock()
	if vlcReady {
		C.kotv_vlc_stop()
	}
}

func vlcSetRate(rate float64) bool {
	vlcMu.Lock()
	defer vlcMu.Unlock()
	return vlcReady && C.kotv_vlc_set_rate(C.float(rate)) >= 0
}

func vlcGetRate() float64 {
	vlcMu.Lock()
	defer vlcMu.Unlock()
	if !vlcReady {
		return 1.0
	}
	return float64(C.kotv_vlc_get_rate())
}

func vlcVideoSize() (int, int) {
	vlcMu.Lock()
	defer vlcMu.Unlock()
	if !vlcReady {
		return 0, 0
	}
	var w, h C.int
	if C.kotv_vlc_video_size(&w, &h) != 0 {
		return 0, 0
	}
	return int(w), int(h)
}

// vlcCycleTrack type: 0=音轨 1=字幕；返回是否成功。
func vlcCycleTrack(kind int) bool {
	vlcMu.Lock()
	defer vlcMu.Unlock()
	return vlcReady && C.kotv_vlc_cycle_track(C.int(kind)) >= 0
}

// vlcTrackList 返回 (id, name) 列表；kind: 0=音轨 1=字幕。
func vlcTrackList(kind int) [][2]string {
	vlcMu.Lock()
	defer vlcMu.Unlock()
	if !vlcReady {
		return nil
	}
	buf := make([]byte, 8192)
	n := C.kotv_vlc_track_list(C.int(kind), (*C.char)(unsafe.Pointer(&buf[0])), C.int(len(buf)))
	if n <= 0 {
		return nil
	}
	var out [][2]string
	for _, line := range strings.Split(strings.TrimRight(string(buf[:cLen(buf)]), "\n"), "\n") {
		if id, name, ok := strings.Cut(line, "\t"); ok {
			out = append(out, [2]string{id, name})
		}
	}
	return out
}

func cLen(b []byte) int {
	for i, c := range b {
		if c == 0 {
			return i
		}
	}
	return len(b)
}

func vlcGetTrack(kind int) int {
	vlcMu.Lock()
	defer vlcMu.Unlock()
	if !vlcReady {
		return -1
	}
	return int(C.kotv_vlc_get_track(C.int(kind)))
}

func vlcSetTrack(kind, id int) bool {
	vlcMu.Lock()
	defer vlcMu.Unlock()
	return vlcReady && C.kotv_vlc_set_track(C.int(kind), C.int(id)) >= 0
}

func vlcAddSubtitle(uri string) bool {
	vlcMu.Lock()
	defer vlcMu.Unlock()
	if !vlcReady {
		return false
	}
	cURI := C.CString(uri)
	defer C.free(unsafe.Pointer(cURI))
	return C.kotv_vlc_add_subtitle(cURI) == 0
}

func vlcSetSpuDelayUs(us int64) bool {
	vlcMu.Lock()
	defer vlcMu.Unlock()
	return vlcReady && C.kotv_vlc_set_spu_delay(C.int64_t(us)) == 0
}

// vlcSetDecodeMode mode: auto / soft / hard。
// 页内 VLC 使用 video callbacks 取 RGBA：硬解常无法出帧，auto 不附加选项最稳。
func vlcSetDecodeMode(mode string) bool {
	vlcMu.Lock()
	defer vlcMu.Unlock()
	v := C.int(-1)
	switch mode {
	case "soft":
		v = 1
	case "hard":
		v = 0
	default:
		v = -1
	}
	return C.kotv_vlc_set_decode(v) == 0
}

func vlcSetRepeat(on bool) {
	vlcMu.Lock()
	defer vlcMu.Unlock()
	if !vlcReady {
		return
	}
	v := C.int(0)
	if on {
		v = 1
	}
	C.kotv_vlc_set_repeat(v)
}

func vlcCanDecode() bool {
	vlcMu.Lock()
	defer vlcMu.Unlock()
	return vlcReady && C.kotv_vlc_can_decode() != 0
}

func vlcPause(pause bool) {
	vlcMu.Lock()
	defer vlcMu.Unlock()
	if !vlcReady {
		return
	}
	v := C.int(0)
	if pause {
		v = 1
	}
	C.kotv_vlc_pause(v)
}

func vlcIsPlaying() bool {
	vlcMu.Lock()
	defer vlcMu.Unlock()
	if !vlcReady {
		return false
	}
	return C.kotv_vlc_is_playing() != 0
}

func vlcEnded() bool {
	vlcMu.Lock()
	defer vlcMu.Unlock()
	if !vlcReady {
		return false
	}
	return C.kotv_vlc_ended() != 0
}

func vlcSetTime(ms int64) {
	vlcMu.Lock()
	defer vlcMu.Unlock()
	if vlcReady {
		C.kotv_vlc_set_time(C.int64_t(ms))
	}
}

func vlcGetTime() int64 {
	vlcMu.Lock()
	defer vlcMu.Unlock()
	if !vlcReady {
		return 0
	}
	return int64(C.kotv_vlc_get_time())
}

func vlcGetLength() int64 {
	vlcMu.Lock()
	defer vlcMu.Unlock()
	if !vlcReady {
		return 0
	}
	return int64(C.kotv_vlc_get_length())
}

func vlcSetVolume(v int) error {
	vlcMu.Lock()
	defer vlcMu.Unlock()
	if !vlcReady {
		return fmt.Errorf("libvlc 未初始化")
	}
	C.kotv_vlc_set_volume(C.int(v))
	return nil
}

func vlcFrameSeq() int64 {
	vlcMu.Lock()
	defer vlcMu.Unlock()
	if !vlcReady {
		return 0
	}
	return int64(C.kotv_vlc_frame_seq())
}

// vlcRecreate 重建底层 player，随后需重新 vlcPlay。
func vlcRecreate() error {
	vlcMu.Lock()
	defer vlcMu.Unlock()
	if !vlcReady {
		return fmt.Errorf("libvlc 未初始化")
	}
	rc := int(C.kotv_vlc_recreate())
	if rc != 0 {
		return fmt.Errorf("VLC 重建失败(code=%d)", rc)
	}
	return nil
}

func vlcSnapshotRGBA() (*image.RGBA, bool) {
	vlcMu.Lock()
	defer vlcMu.Unlock()
	if !vlcReady || vlcHard {
		return nil, false
	}
	frameOnce.Do(func() {
		frameBuf = make([]byte, 3840*2160*4) // 最大 4K
	})
	var w, h C.int
	ok := C.kotv_vlc_take_frame((*C.uint8_t)(unsafe.Pointer(&frameBuf[0])), C.int(len(frameBuf)), &w, &h)
	if ok == 0 || w <= 0 || h <= 0 {
		return nil, false
	}
	iw, ih := int(w), int(h)
	img := image.NewRGBA(image.Rect(0, 0, iw, ih))
	copy(img.Pix, frameBuf[:iw*ih*4])
	return img, true
}

func vlcHardActive() bool {
	vlcMu.Lock()
	defer vlcMu.Unlock()
	return vlcReady && vlcHard
}

func vlcCanHardOutput() bool {
	vlcMu.Lock()
	defer vlcMu.Unlock()
	// Win set_hwnd / macOS set_nsobject / Linux set_xwindow；以 C 侧符号为准。
	return vlcReady && C.kotv_vlc_can_hard_output() != 0
}

func vlcSetHardOutput(hwnd uintptr) error {
	vlcMu.Lock()
	defer vlcMu.Unlock()
	if !vlcReady {
		return fmt.Errorf("libvlc 未初始化")
	}
	if hwnd != 0 && C.kotv_vlc_can_hard_output() == 0 {
		return fmt.Errorf("当前 libvlc 不支持窗口硬渲")
	}
	rc := int(C.kotv_vlc_set_hard_win(C.longlong(hwnd)))
	if rc != 0 {
		return fmt.Errorf("VLC 切换输出失败(code=%d)", rc)
	}
	vlcHard = hwnd != 0
	return nil
}
