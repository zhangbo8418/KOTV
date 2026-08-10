//go:build cgo

package embed

import (
	"image"
	"image/color"
	"os"
	"runtime"
	"sync"
)

// FrameHandler 收到新帧时回调（通常在非 UI 线程；UI 侧需自行切回主线程刷新）。
type FrameHandler func(img *image.RGBA)

// ErrorHandler 播放异常/状态提示回调（非 UI 线程）。
type ErrorHandler func(msg string)

var (
	sinkMu  sync.Mutex
	sink    FrameHandler
	errSink ErrorHandler
)

// SetFrameSink 由 UI VideoSurface 注册；Play 时若已注册则走内嵌。
func SetFrameSink(fn FrameHandler) {
	sinkMu.Lock()
	sink = fn
	sinkMu.Unlock()
}

// SetErrorSink 注册异常/状态提示回调。
func SetErrorSink(fn ErrorHandler) {
	sinkMu.Lock()
	errSink = fn
	sinkMu.Unlock()
}

// FrameSink 当前帧回调。
func FrameSink() FrameHandler {
	sinkMu.Lock()
	defer sinkMu.Unlock()
	return sink
}

func errorSink() ErrorHandler {
	sinkMu.Lock()
	defer sinkMu.Unlock()
	return errSink
}

// HasSink 是否已挂载页内画面。
func HasSink() bool {
	return FrameSink() != nil
}

// BlackFrame 占位黑帧。
func BlackFrame(w, h int) *image.RGBA {
	if w < 2 {
		w = 2
	}
	if h < 2 {
		h = 2
	}
	img := image.NewRGBA(image.Rect(0, 0, w, h))
	c := color.RGBA{0, 0, 0, 255}
	for y := 0; y < h; y++ {
		for x := 0; x < w; x++ {
			img.Set(x, y, c)
		}
	}
	return img
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
