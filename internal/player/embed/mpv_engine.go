//go:build cgo

package embed

import (
	"fmt"
	"image"
	"sync"
	"sync/atomic"
	"time"
)

// MPVEngine 使用 libmpv software render API 输出 RGBA 帧。
type MPVEngine struct {
	mu       sync.Mutex
	opened   bool
	volume   int
	lastURL  string
	lastHist string
	lastImg  *image.RGBA
	pollStop chan struct{}
	playing  atomic.Bool
	paused   atomic.Bool
	ended    atomic.Bool
	seenPlay atomic.Bool // 本轮 Play 后是否曾真正在播
	posMs    atomic.Int64
	durMs    atomic.Int64
}

var (
	mpvEngineMu sync.Mutex
	mpvEngine   *MPVEngine
)

func EnsureMPV() *MPVEngine {
	mpvEngineMu.Lock()
	defer mpvEngineMu.Unlock()
	if mpvEngine == nil {
		mpvEngine = &MPVEngine{volume: 80, lastImg: BlackFrame(16, 9)}
	}
	return mpvEngine
}

func (e *MPVEngine) Open() error {
	e.mu.Lock()
	defer e.mu.Unlock()
	if e.opened {
		return nil
	}
	if err := mpvOpen(); err != nil {
		return err
	}
	e.opened = true
	return nil
}

func (e *MPVEngine) Close() {
	e.Stop()
	e.mu.Lock()
	defer e.mu.Unlock()
	if e.opened {
		mpvClose()
		e.opened = false
	}
}

func (e *MPVEngine) Play(url, histKey string) error {
	if url == "" {
		return fmt.Errorf("空播放地址")
	}
	if err := e.Open(); err != nil {
		return err
	}
	e.mu.Lock()
	e.lastURL = url
	e.lastHist = histKey
	e.stopPollLocked()
	mpvStop()
	if err := mpvPlay(url); err != nil {
		e.mu.Unlock()
		return err
	}
	mpvSetVolume(e.volume)
	if IsRepeatOne() {
		_ = mpvSetPropString("loop-file", "inf")
	} else {
		_ = mpvSetPropString("loop-file", "no")
	}
	e.playing.Store(true)
	e.paused.Store(false)
	e.ended.Store(false)
	e.seenPlay.Store(false)
	e.pollStop = make(chan struct{})
	stop := e.pollStop
	e.mu.Unlock()
	go e.poll(stop)
	return nil
}

func (e *MPVEngine) Stop() {
	e.mu.Lock()
	e.stopPollLocked()
	opened := e.opened
	e.mu.Unlock()
	if opened {
		mpvStop()
	}
	e.playing.Store(false)
	e.paused.Store(false)
	e.ended.Store(false)
	e.posMs.Store(0)
	e.durMs.Store(0)
	e.publish(BlackFrame(16, 9))
}

func (e *MPVEngine) Pause(pause bool) {
	mpvPause(pause)
	e.paused.Store(pause)
}

func (e *MPVEngine) TogglePause() {
	e.Pause(e.IsPlaying())
}

func (e *MPVEngine) IsPlaying() bool {
	return e.playing.Load() && !e.paused.Load() && !e.ended.Load()
}

func (e *MPVEngine) PlaybackEnded() bool {
	return e.ended.Load()
}

func (e *MPVEngine) SeekMs(ms int64) {
	e.ended.Store(false)
	mpvSetTime(ms)
}

func (e *MPVEngine) PositionMs() int64 { return e.posMs.Load() }
func (e *MPVEngine) DurationMs() int64 { return e.durMs.Load() }

func (e *MPVEngine) SetVolume(volume int) {
	if volume < 0 {
		volume = 0
	}
	if volume > 100 {
		volume = 100
	}
	e.mu.Lock()
	e.volume = volume
	e.mu.Unlock()
	mpvSetVolume(volume)
}

func (e *MPVEngine) Volume() int {
	e.mu.Lock()
	defer e.mu.Unlock()
	return e.volume
}

// ---- Enhanced 扩展能力（libmpv 属性直达） ----

func (e *MPVEngine) Caps() Caps {
	return Caps{
		Speed:        true,
		NetSpeed:     true,
		SoftDecode:   true,
		Tracks:       true,
		SubtitleFile: true,
		SubtitleTune: true,
	}
}

func (e *MPVEngine) SetSpeed(v float64) bool { return mpvSetPropDouble("speed", v) }

func (e *MPVEngine) Speed() float64 {
	if v, ok := mpvGetPropDouble("speed"); ok && v > 0 {
		return v
	}
	return 1.0
}

func (e *MPVEngine) VideoSize() (int, int) {
	w, okW := mpvGetPropInt64("width")
	h, okH := mpvGetPropInt64("height")
	if !okW || !okH {
		return 0, 0
	}
	return int(w), int(h)
}

func (e *MPVEngine) CacheSpeedBps() int64 {
	if v, ok := mpvGetPropInt64("cache-speed"); ok {
		return v
	}
	return -1
}

func (e *MPVEngine) SetDecodeMode(mode string) bool {
	// 硬渲窗口可走真正 hwdec；软出画必须 auto-copy 才能取 RGBA。
	hard := mpvHardActive()
	switch mode {
	case "soft":
		return mpvSetPropString("hwdec", "no")
	case "hard":
		if hard {
			return mpvSetPropString("hwdec", "auto")
		}
		return mpvSetPropString("hwdec", "auto-copy")
	default:
		if hard {
			return mpvSetPropString("hwdec", "auto")
		}
		return true
	}
}

// SetHardHWND 切换 MPV 输出到原生窗口（或回软渲）。会重建 handle，需随后 Reload。
func (e *MPVEngine) SetHardHWND(hwnd uintptr) error {
	if err := e.Open(); err != nil {
		return err
	}
	e.mu.Lock()
	e.stopPollLocked()
	e.mu.Unlock()
	if err := mpvSetHardOutput(hwnd); err != nil {
		return err
	}
	return nil
}

func (e *MPVEngine) HardActive() bool { return mpvHardActive() }

// Reload 软硬解等选项变更后重开解码管线；可选保留进度。
func (e *MPVEngine) Reload(preservePos bool) bool {
	e.mu.Lock()
	url := e.lastURL
	hist := e.lastHist
	e.mu.Unlock()
	if url == "" {
		return false
	}
	pos := e.PositionMs()
	if err := e.Play(url, hist); err != nil {
		return false
	}
	if preservePos && pos > 1500 {
		go func() {
			// 等媒体打开后再 seek，避免刚 loadfile 时 time-pos 被重置。
			deadline := time.Now().Add(3 * time.Second)
			for time.Now().Before(deadline) {
				if e.DurationMs() > 0 || e.PositionMs() > 0 {
					break
				}
				time.Sleep(80 * time.Millisecond)
			}
			e.SeekMs(pos)
		}()
	}
	return true
}

// ListTracks 遍历 mpv track-list，kind: "audio" / "sub"。
func (e *MPVEngine) ListTracks(kind string) []TrackInfo {
	count, ok := mpvGetPropInt64("track-list/count")
	if !ok {
		return nil
	}
	var out []TrackInfo
	for i := int64(0); i < count; i++ {
		prefix := fmt.Sprintf("track-list/%d/", i)
		typ, _ := mpvGetPropString(prefix + "type")
		if typ != kind {
			continue
		}
		id, _ := mpvGetPropInt64(prefix + "id")
		title, _ := mpvGetPropString(prefix + "title")
		lang, _ := mpvGetPropString(prefix + "lang")
		sel, _ := mpvGetPropString(prefix + "selected")
		name := title
		if lang != "" {
			if name != "" {
				name += " · " + lang
			} else {
				name = lang
			}
		}
		if name == "" {
			name = fmt.Sprintf("轨道 %d", id)
		}
		out = append(out, TrackInfo{ID: id, Title: name, Selected: sel == "yes"})
	}
	return out
}

func (e *MPVEngine) SelectTrack(kind string, id int64) bool {
	prop := "aid"
	if kind == "sub" {
		prop = "sid"
	}
	if id < 0 {
		return mpvSetPropString(prop, "no")
	}
	return mpvSetPropInt64(prop, id)
}

// CycleTrack 用 mpv cycle 切到下一条音轨/字幕。
func (e *MPVEngine) CycleTrack(kind string) bool {
	prop := "aid"
	if kind == "sub" {
		prop = "sid"
	}
	return mpvCycle(prop)
}

func (e *MPVEngine) AddSubtitleFile(path string) bool {
	return mpvCmd2("sub-add", path)
}

func (e *MPVEngine) SetSubDelaySec(sec float64) bool {
	return mpvSetPropDouble("sub-delay", sec)
}

func (e *MPVEngine) SubDelaySec() (float64, bool) {
	return mpvGetPropDouble("sub-delay")
}

func (e *MPVEngine) SetSubFontSize(size float64) bool {
	return mpvSetPropDouble("sub-font-size", size)
}

func (e *MPVEngine) SubFontSize() (float64, bool) {
	return mpvGetPropDouble("sub-font-size")
}

func (e *MPVEngine) LastFrame() *image.RGBA {
	e.mu.Lock()
	defer e.mu.Unlock()
	return e.lastImg
}

func (e *MPVEngine) stopPollLocked() {
	if e.pollStop != nil {
		close(e.pollStop)
		e.pollStop = nil
	}
}

func (e *MPVEngine) publish(img *image.RGBA) {
	e.mu.Lock()
	e.lastImg = img
	e.mu.Unlock()
	if sink := FrameSink(); sink != nil {
		sink(img)
	}
}

func (e *MPVEngine) poll(stop <-chan struct{}) {
	frameTicker := time.NewTicker(16 * time.Millisecond)
	progressTicker := time.NewTicker(500 * time.Millisecond)
	defer frameTicker.Stop()
	defer progressTicker.Stop()
	for {
		select {
		case <-stop:
			return
		case <-frameTicker.C:
			if img, ok := mpvSnapshotRGBA(); ok && img != nil {
				e.publish(img)
			}
		case <-progressTicker.C:
			pos := mpvGetTime()
			e.posMs.Store(pos)
			dur := mpvGetLength()
			e.durMs.Store(dur)
			live := mpvIsPlaying()
			if live {
				e.seenPlay.Store(true)
				if !e.paused.Load() {
					e.playing.Store(true)
				}
			}
			if mpvEofReached() && e.seenPlay.Load() && e.playing.Load() && !e.paused.Load() {
				if IsRepeatOne() {
					continue
				}
				nearEnd := dur > 0 && pos >= dur-3000
				playedEnough := pos >= 8000
				if nearEnd || (dur <= 0 && playedEnough) {
					e.playing.Store(false)
					e.ended.Store(true)
				}
			} else if !live && e.seenPlay.Load() && e.playing.Load() && !e.paused.Load() {
				// libmpv 已停但未标 eof：按播完处理（部分源 eof-reached 不可靠）。
				if dur > 0 && pos >= dur-1500 {
					e.playing.Store(false)
					e.ended.Store(true)
				}
			}
		}
	}
}
