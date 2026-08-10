//go:build cgo

package embed

import (
	"image"
	"sync"
)

// Controller 是 VideoSurface 可操作的页内播放后端。
type Controller interface {
	Open() error
	Close()
	Play(url, histKey string) error
	Stop()
	Pause(bool)
	TogglePause()
	IsPlaying() bool
	// PlaybackEnded 是否已真正播完（如 MPV eof-reached）。
	PlaybackEnded() bool
	SeekMs(int64)
	PositionMs() int64
	DurationMs() int64
	SetVolume(int)
	Volume() int
	LastFrame() *image.RGBA
}

// Caps 描述后端支持的扩展功能，UI 据此隐藏不支持的按钮。
type Caps struct {
	Speed        bool // 倍速
	NetSpeed     bool // 网速显示
	SoftDecode   bool // 软/硬解切换
	Tracks       bool // 音轨/字幕轨道列举与选择
	SubtitleFile bool // 外挂本地字幕
	SubtitleTune bool // 字幕字号/延迟调整
}

// TrackInfo 一条音轨/字幕轨道。
type TrackInfo struct {
	ID       int64
	Title    string
	Selected bool
}

// Enhanced 页内后端的可选扩展能力（倍速/分辨率/网速/解码/音轨/字幕）。
// UI 通过类型断言探测；不支持的操作返回 false / 负值。
type Enhanced interface {
	Caps() Caps
	SetSpeed(v float64) bool
	Speed() float64
	VideoSize() (w, h int)
	CacheSpeedBps() int64 // <0 表示不支持
	// SetDecodeMode mode: auto / soft / hard。
	// auto 由播放器按系统与驱动能力选择，无法硬解时回退软解。
	SetDecodeMode(mode string) bool
	// Reload 重载当前片源；解码方式等需重开解码管线的设置切换后应调用。
	// preservePos 为 true 时尽量跳回切换前进度。
	Reload(preservePos bool) bool
	// ListTracks kind: "audio" / "sub"
	ListTracks(kind string) []TrackInfo
	SelectTrack(kind string, id int64) bool
	// CycleTrack 循环切到下一条音轨/字幕；无多轨时返回 false。
	CycleTrack(kind string) bool
	AddSubtitleFile(path string) bool
	// SubDelaySec / SubFontSize：不支持时返回 false
	SetSubDelaySec(sec float64) bool
	SubDelaySec() (float64, bool)
	SetSubFontSize(size float64) bool
	SubFontSize() (float64, bool)
}

// ActiveEnhanced 返回当前后端的扩展能力（不支持时 ok=false）。
func ActiveEnhanced() (Enhanced, bool) {
	e, ok := Active().(Enhanced)
	return e, ok
}

var (
	activeMu sync.RWMutex
	active   Controller
)

// SetActive 设置当前页内后端（MPV）。
func SetActive(controller Controller) {
	activeMu.Lock()
	active = controller
	activeMu.Unlock()
}

// Active 返回当前页内后端；默认使用 MPV。
func Active() Controller {
	activeMu.RLock()
	controller := active
	activeMu.RUnlock()
	if controller != nil {
		return controller
	}
	controller = EnsureMPV()
	SetActive(controller)
	return controller
}

// StopAll 页面退出时同时停止两个后端。
func StopAll() {
	EnsureMPV().Stop()
}

// MPVAvailable 表示捆绑 libmpv 可用于页内软件渲染。
func MPVAvailable() bool {
	return mpvProbe()
}
