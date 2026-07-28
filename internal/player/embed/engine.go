//go:build cgo

// Package embed 提供页内 VLC 软渲染播放。
// 运行时 dlopen 捆绑 libvlc，编译期不依赖系统 VLC SDK。
// 防卡死设计：
// - 所有对 libvlc 的“变更类”调用（play/stop/pause/seek/volume/recreate）都投递到
// 单一 worker goroutine 串行执行；libvlc_media_player_stop 是同步阻塞调用，若放在
// UI 线程会冻结界面，这里改为异步，UI 立即返回。
// - 进度/状态用原子量缓存，由采集 loop 周期性刷新；UI 读取原子量，绝不进 CGO 阻塞。
// - watchdog 监控帧序号：想播且未暂停但长时间无新帧 → 认为管线卡死，投递 recreate
// 重建底层 player 并重连，同时通过 errSink 通知 UI。
package embed

import (
	"fmt"
	"image"
	"image/color"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

// FrameHandler 收到新帧时回调（通常在非 UI 线程；UI 侧需自行切回主线程刷新）。
type FrameHandler func(img *image.RGBA)

// ErrorHandler 播放异常/状态提示回调（非 UI 线程）。
type ErrorHandler func(msg string)

const (
	frameInterval   = 16 * time.Millisecond // ~60Hz 采帧；UI 侧合并推送，避免堆积
	progInterval    = 500 * time.Millisecond
	watchdogEvery   = 2 * time.Second
	stallThreshold  = 12 * time.Second // 想播但无新帧超过该时长判定卡死
	cmdQueueCap     = 64
	maxRecoverBurst = 3 // 连续重连保护
)

type cmdKind int

const (
	cmdPlay cmdKind = iota
	cmdStop
	cmdPause
	cmdSeek
	cmdVolume
	cmdRecreate
)

type command struct {
	kind cmdKind
	url  string
	hist string
	ms   int64
	flag bool
	val  int
}

// Engine 内嵌播放引擎。
type Engine struct {
	mu      sync.Mutex
	opened  bool
	onFrame FrameHandler
	histKey string
	playURL string
	volume  int
	lastImg *image.RGBA

	cmdCh    chan command
	lifeStop chan struct{}
	life     sync.WaitGroup

	wantPlay    atomic.Bool // 用户意图：应处于播放
	paused      atomic.Bool // 已暂停
	realPlaying atomic.Bool // libvlc 实际播放态（缓存）
	ended       atomic.Bool // 真正播完（libvlc_Ended）
	seenPlaying atomic.Bool // 本轮 Play 后是否曾进入 Playing（防旧 Ended 误触）
	posMs       atomic.Int64 // 当前位置（缓存）
	durMs       atomic.Int64 // 总时长（缓存）
	lastFrameNs atomic.Int64 // 最近一帧到达时间
	lastFrameSeq atomic.Int64 // 最近一次看到的 C 侧帧序号（watchdog）
	recovers    atomic.Int32 // 连续重连次数
}

var (
	globalMu sync.Mutex
	global   *Engine
	sinkMu   sync.Mutex
	sink     FrameHandler
	errSink  ErrorHandler
)

// SetFrameSink 由 UI VideoSurface 注册；Play 时若已注册则走内嵌。
func SetFrameSink(fn FrameHandler) {
	sinkMu.Lock()
	sink = fn
	sinkMu.Unlock()
	if e := Current(); e != nil {
		e.mu.Lock()
		e.onFrame = fn
		e.mu.Unlock()
	}
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

// Current 返回全局引擎（懒创建）。
func Current() *Engine {
	globalMu.Lock()
	defer globalMu.Unlock()
	return global
}

// Ensure 确保引擎已创建（未 Open）。
func Ensure() *Engine {
	globalMu.Lock()
	defer globalMu.Unlock()
	if global == nil {
		global = &Engine{volume: 80}
	}
	return global
}

// Available 捆绑 libvlc 是否可加载。
func Available() bool {
	return vlcProbe()
}

// Open 加载捆绑 libvlc 并启动 worker/采集/watchdog。
func (e *Engine) Open() error {
	e.mu.Lock()
	defer e.mu.Unlock()
	if e.opened {
		return nil
	}
	if err := vlcOpen(); err != nil {
		return err
	}
	e.opened = true
	e.onFrame = FrameSink()
	e.cmdCh = make(chan command, cmdQueueCap)
	e.lifeStop = make(chan struct{})
	e.life.Add(3)
	go e.worker()
	go e.captureLoop()
	go e.watchdog()
	return nil
}

// Close 停止并释放引擎。
func (e *Engine) Close() {
	e.mu.Lock()
	if !e.opened {
		e.mu.Unlock()
		return
	}
	e.opened = false
	stop := e.lifeStop
	e.lifeStop = nil
	e.cmdCh = nil
	e.mu.Unlock()

	e.wantPlay.Store(false)
	if stop != nil {
		close(stop)
	}
	e.life.Wait() // 等 worker 退出后再释放，避免 worker 调用已卸载的 libvlc
	vlcClose()
	e.realPlaying.Store(false)
}

// enqueue 非阻塞投递命令；队列满时另起 goroutine 交付，绝不阻塞调用方（UI）。
func (e *Engine) enqueue(c command) {
	e.mu.Lock()
	ch := e.cmdCh
	e.mu.Unlock()
	if ch == nil {
		return
	}
	select {
	case ch <- c:
	default:
		go func() {
			defer func() { _ = recover() }() // Close 可能已置空/关闭
			select {
			case ch <- c:
			case <-time.After(3 * time.Second):
			}
		}()
	}
}

// Play 播放 URL（异步）；错误经 ErrorSink 反馈。Open 失败同步返回。
func (e *Engine) Play(url, histKey string) error {
	if url == "" {
		return fmt.Errorf("空播放地址")
	}
	if err := e.Open(); err != nil {
		return err
	}
	e.recovers.Store(0)
	e.ended.Store(false)
	e.seenPlaying.Store(false)
	e.enqueue(command{kind: cmdPlay, url: url, hist: histKey})
	return nil
}

// Stop 停止并清帧（异步）。
func (e *Engine) Stop() {
	e.wantPlay.Store(false)
	e.ended.Store(false)
	e.seenPlaying.Store(false)
	e.enqueue(command{kind: cmdStop})
}

// Pause 设置暂停（异步）。
func (e *Engine) Pause(pause bool) {
	e.paused.Store(pause)
	e.enqueue(command{kind: cmdPause, flag: pause})
}

// TogglePause 切换播放/暂停。
func (e *Engine) TogglePause() {
	e.Pause(e.IsPlaying())
}

// IsPlaying 用户视角的播放态（想播、未暂停、未播完），稳定不阻塞。
func (e *Engine) IsPlaying() bool {
	return e.wantPlay.Load() && !e.paused.Load() && !e.ended.Load()
}

// PlaybackEnded 是否已真正播完（libvlc_Ended）。
func (e *Engine) PlaybackEnded() bool {
	return e.ended.Load()
}

// SeekMs 跳转毫秒（异步）。
func (e *Engine) SeekMs(ms int64) {
	e.ended.Store(false)
	e.enqueue(command{kind: cmdSeek, ms: ms})
}

// PositionMs / DurationMs 进度（原子缓存，不阻塞）。
func (e *Engine) PositionMs() int64 { return e.posMs.Load() }
func (e *Engine) DurationMs() int64 { return e.durMs.Load() }

// SetVolume 0-100（异步下发，立即记录）。
func (e *Engine) SetVolume(v int) {
	if v < 0 {
		v = 0
	}
	if v > 100 {
		v = 100
	}
	e.mu.Lock()
	e.volume = v
	e.mu.Unlock()
	e.enqueue(command{kind: cmdVolume, val: v})
}

func (e *Engine) Volume() int {
	e.mu.Lock()
	defer e.mu.Unlock()
	return e.volume
}

// ---- Enhanced 扩展能力（libvlc 直达调用，符号缺失时降级为不支持） ----

func (e *Engine) Caps() Caps {
	// SoftDecode：依赖 libvlc media_add_option；未加载时仍先露出按钮，点选时再降级。
	return Caps{
		Speed:        true,
		NetSpeed:     false, // libvlc 无稳定网速属性
		SoftDecode:   true,
		Tracks:       true,
		SubtitleFile: true,
		SubtitleTune: false, // 仅延迟可调、无字号，统一隐藏微调
	}
}

func (e *Engine) SetSpeed(v float64) bool { return vlcSetRate(v) }
func (e *Engine) Speed() float64          { return vlcGetRate() }

func (e *Engine) VideoSize() (int, int) { return vlcVideoSize() }

// CacheSpeedBps libvlc 无稳定的网速属性，返回不支持。
func (e *Engine) CacheSpeedBps() int64 { return -1 }

// SetDecodeMode 页内 VLC：软出画时 hard 与 auto 均不强制（回调路径硬解常无帧）。
// 硬渲窗口下 hard/auto 启用 :avcodec-hw=any。
func (e *Engine) SetDecodeMode(mode string) bool {
	if !vlcCanDecode() {
		return false
	}
	if mode == "soft" {
		return vlcSetDecodeMode("soft")
	}
	if vlcHardActive() {
		return vlcSetDecodeMode("hard")
	}
	return vlcSetDecodeMode("auto")
}

// SetHardHWND 切换 VLC 输出到原生窗口（或回回调软渲）。会重建 player，需随后 Reload。
func (e *Engine) SetHardHWND(hwnd uintptr) error {
	if err := e.Open(); err != nil {
		return err
	}
	if hwnd != 0 && !vlcCanHardOutput() {
		return fmt.Errorf("当前 libvlc 不支持窗口硬渲")
	}
	return vlcSetHardOutput(hwnd)
}

func (e *Engine) HardActive() bool { return vlcHardActive() }

// Reload 重载当前片源：软硬解切换后重建 media，可选保留进度。
func (e *Engine) Reload(preservePos bool) bool {
	e.mu.Lock()
	url := e.playURL
	hist := e.histKey
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
			deadline := time.Now().Add(3 * time.Second)
			for time.Now().Before(deadline) {
				if e.DurationMs() > 0 {
					break
				}
				time.Sleep(80 * time.Millisecond)
			}
			e.SeekMs(pos)
		}()
	}
	return true
}

func (e *Engine) ListTracks(kind string) []TrackInfo {
	k := 0
	if kind == "sub" {
		k = 1
	}
	cur := vlcGetTrack(k)
	var out []TrackInfo
	for _, t := range vlcTrackList(k) {
		id, err := strconv.ParseInt(t[0], 10, 64)
		if err != nil {
			continue
		}
		name := t[1]
		if name == "" {
			name = fmt.Sprintf("轨道 %d", id)
		}
		out = append(out, TrackInfo{ID: id, Title: name, Selected: int(id) == cur})
	}
	return out
}

func (e *Engine) SelectTrack(kind string, id int64) bool {
	k := 0
	if kind == "sub" {
		k = 1
	}
	return vlcSetTrack(k, int(id))
}

// CycleTrack 用 libvlc 轨道描述表循环切换。
func (e *Engine) CycleTrack(kind string) bool {
	k := 0
	if kind == "sub" {
		k = 1
	}
	return vlcCycleTrack(k)
}

func (e *Engine) AddSubtitleFile(path string) bool {
	u := url.URL{Scheme: "file", Path: path}
	return vlcAddSubtitle(u.String())
}

func (e *Engine) SetSubDelaySec(sec float64) bool {
	return vlcSetSpuDelayUs(int64(sec * 1e6))
}

func (e *Engine) SubDelaySec() (float64, bool) { return 0, false }
func (e *Engine) SetSubFontSize(float64) bool  { return false }
func (e *Engine) SubFontSize() (float64, bool) { return 0, false }

// LastFrame 最近一帧（可给 UI 立即刷新）。
func (e *Engine) LastFrame() *image.RGBA {
	e.mu.Lock()
	defer e.mu.Unlock()
	return e.lastImg
}

// ---- 内部：命令执行（均在 worker goroutine 串行运行）----

func (e *Engine) worker() {
	defer e.life.Done()
	stop := e.lifeStop
	ch := e.cmdCh
	for {
		select {
		case <-stop:
			return
		case c := <-ch:
			e.exec(c)
		}
	}
}

func (e *Engine) exec(c command) {
	switch c.kind {
	case cmdPlay:
		vlcStop()
		e.clearFrame()
		if err := vlcPlay(c.url); err != nil {
			e.wantPlay.Store(false)
			e.notify("播放失败: " + err.Error())
			return
		}
		_ = vlcSetVolume(e.Volume())
		e.mu.Lock()
		e.playURL = c.url
		e.histKey = c.hist
		e.mu.Unlock()
		e.wantPlay.Store(true)
		e.paused.Store(false)
		e.ended.Store(false)
		e.seenPlaying.Store(false)
		e.lastFrameNs.Store(time.Now().UnixNano())
	case cmdStop:
		vlcStop()
		e.wantPlay.Store(false)
		e.paused.Store(false)
		e.realPlaying.Store(false)
		e.seenPlaying.Store(false)
		e.posMs.Store(0)
		e.durMs.Store(0)
		e.clearFrame()
	case cmdPause:
		vlcPause(c.flag)
		e.paused.Store(c.flag)
	case cmdSeek:
		vlcSetTime(c.ms)
		e.lastFrameNs.Store(time.Now().UnixNano()) // seek 后给缓冲留时间，避免误判卡死
	case cmdVolume:
		_ = vlcSetVolume(c.val)
	case cmdRecreate:
		e.mu.Lock()
		url := e.playURL
		e.mu.Unlock()
		if url == "" || !e.wantPlay.Load() {
			return
		}
		pos := e.posMs.Load()
		if err := vlcRecreate(); err != nil {
			e.notify("重连失败: " + err.Error())
			return
		}
		if err := vlcPlay(url); err != nil {
			e.notify("重连失败: " + err.Error())
			return
		}
		_ = vlcSetVolume(e.Volume())
		e.lastFrameNs.Store(time.Now().UnixNano())
		if pos > 1500 {
			go func(ms int64) {
				deadline := time.Now().Add(5 * time.Second)
				for time.Now().Before(deadline) {
					if e.DurationMs() > 0 || vlcIsPlaying() {
						break
					}
					time.Sleep(80 * time.Millisecond)
				}
				vlcSetTime(ms)
				e.posMs.Store(ms)
				e.lastFrameNs.Store(time.Now().UnixNano())
			}(pos)
		}
	}
}

func (e *Engine) notify(msg string) {
	if fn := errorSink(); fn != nil {
		go fn(msg)
	}
}

func (e *Engine) clearFrame() {
	img := image.NewRGBA(image.Rect(0, 0, 2, 2))
	e.mu.Lock()
	e.lastImg = img
	fn := e.onFrame
	e.mu.Unlock()
	if fn != nil {
		go fn(img)
	}
}

// captureLoop 采帧 + 刷新进度缓存。
func (e *Engine) captureLoop() {
	defer e.life.Done()
	stop := e.lifeStop
	frameTick := time.NewTicker(frameInterval)
	progTick := time.NewTicker(progInterval)
	defer frameTick.Stop()
	defer progTick.Stop()
	for {
		select {
		case <-stop:
			return
		case <-frameTick.C:
			img, ok := vlcSnapshotRGBA()
			seq := vlcFrameSeq()
			if seq > 0 && seq != e.lastFrameSeq.Load() {
				e.lastFrameSeq.Store(seq)
				e.lastFrameNs.Store(time.Now().UnixNano())
				e.recovers.Store(0)
			}
			if !ok || img == nil {
				continue
			}
			e.lastFrameNs.Store(time.Now().UnixNano())
			e.recovers.Store(0) // 有帧即视为已恢复
			e.mu.Lock()
			e.lastImg = img
			fn := e.onFrame
			e.mu.Unlock()
			if fn != nil {
				fn(img)
			}
		case <-progTick.C:
			e.posMs.Store(vlcGetTime())
			e.durMs.Store(vlcGetLength())
			playing := vlcIsPlaying()
			e.realPlaying.Store(playing)
			if playing {
				e.seenPlaying.Store(true)
			}
			// 仅在接近片尾时认 Ended，避免开播瞬间/缓冲失败误标结束。
			if vlcEnded() && e.seenPlaying.Load() && e.wantPlay.Load() && !e.paused.Load() {
				if IsRepeatOne() {
					continue
				}
				pos := e.posMs.Load()
				dur := e.durMs.Load()
				nearEnd := dur > 0 && pos >= dur-3000
				playedEnough := pos >= 8000
				if nearEnd || (dur <= 0 && playedEnough) {
					e.wantPlay.Store(false)
					e.ended.Store(true)
				}
			}
		}
	}
}

// watchdog 卡死检测 + 自动重连。
func (e *Engine) watchdog() {
	defer e.life.Done()
	stop := e.lifeStop
	t := time.NewTicker(watchdogEvery)
	defer t.Stop()
	for {
		select {
		case <-stop:
			return
		case <-t.C:
			if vlcHardActive() {
				// 硬渲无 RGBA 帧；用播放态刷新存活时间，避免误触发 recreate。
				if e.wantPlay.Load() && !e.paused.Load() && vlcIsPlaying() {
					e.lastFrameNs.Store(time.Now().UnixNano())
					e.lastFrameSeq.Store(vlcFrameSeq())
				}
				continue
			}
			if !e.wantPlay.Load() || e.paused.Load() {
				continue
			}
			// 优先看 C 侧 display 序号：即使 take_frame 失败也能发现管线是否在出帧。
			seq := vlcFrameSeq()
			prev := e.lastFrameSeq.Load()
			if seq > 0 {
				if seq != prev {
					e.lastFrameSeq.Store(seq)
					e.lastFrameNs.Store(time.Now().UnixNano())
					e.recovers.Store(0)
					continue
				}
			}
			last := e.lastFrameNs.Load()
			if last == 0 {
				continue
			}
			if time.Since(time.Unix(0, last)) < stallThreshold {
				continue
			}
			e.mu.Lock()
			url := e.playURL
			e.mu.Unlock()
 // 磁力本地流卡顿是缓冲，重建会从头播。
			if strings.Contains(url, "/proxy/bt/") {
				e.notify("磁力缓冲中，请稍候…")
				e.lastFrameNs.Store(time.Now().UnixNano())
				continue
			}
			if e.recovers.Add(1) > maxRecoverBurst {
				e.notify("多次重连失败，请检查网络或换源")
				e.wantPlay.Store(false)
				e.enqueue(command{kind: cmdStop})
				continue
			}
			e.notify("画面卡住，正在重连…")
			e.enqueue(command{kind: cmdRecreate})
			e.lastFrameNs.Store(time.Now().UnixNano())
		}
	}
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
