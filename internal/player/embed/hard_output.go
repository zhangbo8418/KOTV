//go:build cgo

package embed

// HardOutput 将页内播放切到原生窗口硬渲。
// 句柄含义：Windows HWND / macOS NSView* / Linux X11 Window；MPV 统一走 wid。
// 切换会重建底层输出管线，调用方应保存进度并在成功后 Reload/Play+Seek。
type HardOutput interface {
	// SetHardHWND id!=0 进入硬渲；id==0 回到软件 RGBA。
	SetHardHWND(id uintptr) error
	HardActive() bool
}

// ActiveHardOutput 当前后端若支持硬渲则返回。
func ActiveHardOutput() (HardOutput, bool) {
	h, ok := Active().(HardOutput)
	return h, ok
}
