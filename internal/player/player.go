package player

import (
	"fmt"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/bobo/KOTV/internal/player/embed"
	appruntime "github.com/bobo/KOTV/internal/runtime"
	"github.com/bobo/KOTV/internal/settings"
	"github.com/bobo/KOTV/internal/thunder"
)

// Progress 播放进度回调。
type Progress struct {
	PositionMs int64
	DurationMs int64
	URL        string
	HistoryKey string
}

var (
	mu           sync.Mutex
	current      *exec.Cmd
	ipcSock      string
	historyKey   string
	playURL      string
	onProgress   func(Progress)
	progressStop chan struct{}
	lastPosition int64
	lastDuration int64
)

// SetProgressHandler 设置进度回调（用于写入历史续播）。
func SetProgressHandler(fn func(Progress)) {
	mu.Lock()
	onProgress = fn
	mu.Unlock()
}

// PreferEmbed 当前设置是否应为页内嵌入（innie#mpv）。
func PreferEmbed() bool {
	player := settings.Get(settings.Player)
	if player == "" {
		player = "innie#mpv"
	}
	parts := strings.SplitN(player, "#", 2)
	mode := parts[0]
	name := "mpv"
	if len(parts) > 1 && parts[1] != "" {
		name = strings.ToLower(parts[1])
	}
	return mode == "innie" && name == "mpv"
}

// Play 严格按设置启动对应播放器；innie#mpv 且已挂载画面时走页内嵌入。
func Play(url string, histKey string) error {
	player := settings.Get(settings.Player)
	if player == "" {
		player = "innie#mpv"
	}
	parts := strings.SplitN(player, "#", 2)
	mode := parts[0]
	name := "mpv"
	if len(parts) > 1 && parts[1] != "" {
		name = strings.ToLower(parts[1])
	}
	if mode == "" {
		mode = "innie"
	}
	name = strings.ToLower(name)

	log.Printf("播放器设置=%s → mode=%s name=%s url=%s", player, mode, name, url)

	// Source.fetch(Thunder)：magnet/thunder → 本地 HTTP。
	if thunder.Match(url) {
		stream, err := thunder.Fetch(url)
		if err != nil {
			return fmt.Errorf("磁力链接解析失败: %w", err)
		}
		log.Printf("thunder fetch → %s", stream)
		url = stream
	} else if isEd2k(url) {
		if err := openSystemURL(url); err != nil {
			return fmt.Errorf("电驴链接需用系统下载器打开: %w", err)
		}
		mu.Lock()
		historyKey = histKey
		playURL = url
		mu.Unlock()
		return nil
	}

	if name == "vlc" {
		name = "mpv"
	}
	if mode == "innie" && name == "mpv" {
		if !embed.HasSink() {
			return fmt.Errorf("页内播放器未就绪：请在详情/直播页播放")
		}
		if !embed.MPVAvailable() {
			return fmt.Errorf("未找到捆绑 libmpv：页内 MPV 由 Flutter media_kit 提供，或改选外部 MPV")
		}
		Stop() // 停掉旁路进程
		eng := embed.Controller(embed.EnsureMPV())
		// 切内核时只停另一个；同内核换台/回看由 Play 内部 stop+load，勿 StopAll。
		if prev := embed.Active(); prev != nil && prev != eng {
			prev.Stop()
		}
		embed.SetActive(eng)
		// 解码方式必须在打开片源前设置：MPV 的 hwdec 影响首帧，
		// VLC 的 :avcodec-hw 只能在建 media 时下发。不支持的内核会返回 false，无副作用。
		if enhanced, ok := eng.(embed.Enhanced); ok {
			mode := settings.Get(settings.PlayerDecode)
			if mode == "" {
				mode = "auto"
			}
			enhanced.SetDecodeMode(mode)
		}
		if err := eng.Play(url, histKey); err != nil {
			return fmt.Errorf("内嵌 %s 失败: %w", displayName(name), err)
		}
		if volume, err := strconv.Atoi(settings.Get(settings.PlayerVolume)); err == nil {
			eng.SetVolume(volume)
		}
		if enhanced, ok := eng.(embed.Enhanced); ok {
			if speed, err := strconv.ParseFloat(settings.Get(settings.PlayerSpeed), 64); err == nil && speed > 0 {
				enhanced.SetSpeed(speed)
			}
		}
		mu.Lock()
		historyKey = histKey
		playURL = url
		mu.Unlock()
		return nil
	}

	if mode == "innie" {
		// innie#mpv 等：旁路窗口
		if err := playSidecar(name, url, histKey); err != nil {
			log.Printf("内置旁路播放失败(%s): %v，尝试外部同名播放器", name, err)
			if err2 := playExternal(name, url); err2 != nil {
				return fmt.Errorf("内置 %s 失败: %v；外部也失败: %w", displayName(name), err, err2)
			}
		}
		return nil
	}
	return playExternal(name, url)
}

// PlaySimple 兼容旧调用。
func PlaySimple(url string) error {
	return Play(url, "")
}

func displayName(name string) string {
	switch strings.ToLower(name) {
	case "vlc":
		return "VLC"
	case "mpv":
		return "MPV"
	case "iina":
		return "IINA"
	default:
		return name
	}
}

func playSidecar(name, url, histKey string) error {
	mu.Lock()
	defer mu.Unlock()
	stopLocked()
	embed.StopAll()

	historyKey = histKey
	playURL = url
	lastPosition = -1
	lastDuration = 0

	var cmd *exec.Cmd
	switch strings.ToLower(name) {
	case "mpv", "":
		bin := findPlayer("mpv")
		if bin == "" {
			return fmt.Errorf("未找到 MPV")
		}
		if resolved, err := filepath.EvalSymlinks(bin); err == nil && resolved != "" {
			bin = resolved
		}
		ipcSock = mpvNewIPCPath()
		mpvCleanupIPC(ipcSock)
		args := []string{
			"--force-window=yes",
			"--keep-open=yes",
			"--idle=no",
			"--input-ipc-server=" + ipcSock,
		}
		cmd = exec.Command(bin, append(args, url)...)
		// @executable_path/lib 依赖：工作目录放到二进制旁（mpv.app/.../MacOS）
		cmd.Dir = filepath.Dir(bin)
		cmd.Stdout = nil
		cmd.Stderr = nil
		log.Printf("启动内置 MPV: bin=%s dir=%s url=%s", bin, cmd.Dir, url)
	case "vlc":
		bin := findPlayer("vlc")
		if bin == "" {
			return fmt.Errorf("未找到 VLC")
		}
		cmd = exec.Command(bin, "--no-video-title-show", url)
		ipcSock = ""
	case "iina":
		if runtime.GOOS != "darwin" {
			return fmt.Errorf("IINA 仅支持 macOS")
		}
		if !appExists("IINA") {
			return fmt.Errorf("未安装 IINA")
		}
		cmd = exec.Command("open", "-a", "IINA", url)
		ipcSock = ""
	default:
		return fmt.Errorf("不支持的内置播放器: %s", name)
	}
	if err := cmd.Start(); err != nil {
		return err
	}
	current = cmd
	if ipcSock != "" {
		progressStop = make(chan struct{})
		go pollMPVProgress(ipcSock, progressStop)
	}
	go func() {
		_ = cmd.Wait()
		mu.Lock()
		if current == cmd {
			flushProgressLocked()
			current = nil
			ipcSock = ""
		}
		mu.Unlock()
	}()
	return nil
}

func pollMPVProgress(sock string, stop <-chan struct{}) {
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		if mpvIPCReady(sock) {
			break
		}
		select {
		case <-stop:
			return
		case <-time.After(100 * time.Millisecond):
		}
	}
	ticker := time.NewTicker(2 * time.Second)
	defer ticker.Stop()
	for {
		select {
		case <-stop:
			return
		case <-ticker.C:
			pos, dur := mpvGetTime(sock)
			if pos < 0 {
				continue
			}
			select {
			case <-stop:
				return
			default:
			}
			mu.Lock()
			if ipcSock != sock {
				mu.Unlock()
				return
			}
			fn := onProgress
			key := historyKey
			u := playURL
			posMs := int64(pos * 1000)
			durMs := int64(dur * 1000)
			lastPosition = posMs
			lastDuration = durMs
			mu.Unlock()
			if fn != nil && key != "" {
				fn(Progress{
					PositionMs: posMs,
					DurationMs: durMs,
					URL:        u,
					HistoryKey: key,
				})
			}
		}
	}
}

func mpvGetTime(sock string) (pos, dur float64) {
	return mpvIPCGetTime(sock)
}

func flushProgressLocked() {
	if onProgress == nil || historyKey == "" || lastPosition < 0 {
		return
	}
	fn := onProgress
	p := Progress{
		PositionMs: lastPosition,
		DurationMs: lastDuration,
		URL:        playURL,
		HistoryKey: historyKey,
	}
	// 回调可能写数据库或刷新 UI，不应在 player 全局锁内同步执行。
	go fn(p)
}

func playExternal(name, url string) error {
	switch strings.ToLower(name) {
	case "iina":
		if runtime.GOOS != "darwin" {
			return fmt.Errorf("IINA 仅支持 macOS")
		}
		if !appExists("IINA") {
			return fmt.Errorf("未安装 IINA（/Applications/IINA.app）")
		}
		return exec.Command("open", "-a", "IINA", url).Start()
	case "vlc":
		// 系统安装的外部 VLC
		if bin := findPlayer("vlc"); bin != "" {
			if runtime.GOOS == "darwin" {
				if app := vlcAppBundle(bin); app != "" {
					return exec.Command("open", "-a", app, url).Start()
				}
			}
			return exec.Command(bin, url).Start()
		}
		if runtime.GOOS == "darwin" && appExists("VLC") {
			return exec.Command("open", "-a", "VLC", url).Start()
		}
		return fmt.Errorf("未找到外部 VLC：请先安装系统 VLC")
	case "mpv":
		bin := findPlayer("mpv")
		if bin == "" {
			return fmt.Errorf("未找到外部 MPV：请先安装 mpv")
		}
		if resolved, err := filepath.EvalSymlinks(bin); err == nil && resolved != "" {
			bin = resolved
		}
		cmd := exec.Command(bin, url)
		cmd.Dir = filepath.Dir(bin)
		return cmd.Start()
	default:
		return fmt.Errorf("未知播放器: %s", name)
	}
}

// vlcAppBundle 从可执行路径还原 .app 包路径，便于 open -a。
func vlcAppBundle(bin string) string {
	const marker = ".app/"
	idx := strings.Index(bin, marker)
	if idx < 0 {
		return ""
	}
	return bin[:idx+len(".app")]
}

func appExists(name string) bool {
	if runtime.GOOS != "darwin" {
		return false
	}
	_, err := os.Stat("/Applications/" + name + ".app")
	return err == nil
}

// Stop 停止旁路与内嵌播放器。
func Stop() {
	mu.Lock()
	defer mu.Unlock()
	stopLocked()
	embed.StopAll()
}

func stopLocked() {
	if progressStop != nil {
		close(progressStop)
		progressStop = nil
	}
	flushProgressLocked()
	if current != nil && current.Process != nil {
		_ = current.Process.Kill()
		current = nil
	}
	if ipcSock != "" {
		mpvCleanupIPC(ipcSock)
		ipcSock = ""
	}
}

// findPlayer 返回可执行路径；找不到返回空字符串（不再返回裸命令名冒充成功）。
func findPlayer(name string) string {
	switch strings.ToLower(name) {
	case "mpv", "":
		if p := appruntime.MPV(); p != "" {
			return p
		}
	case "vlc":
		if p := appruntime.VLC(); p != "" {
			return p
		}
	}
	if p, err := exec.LookPath(name); err == nil {
		return p
	}
	if runtime.GOOS == "darwin" {
		candidates := map[string]string{
			"vlc": "/Applications/VLC.app/Contents/MacOS/VLC",
			"mpv": "/opt/homebrew/bin/mpv",
		}
		if p, ok := candidates[strings.ToLower(name)]; ok {
			if _, err := os.Stat(p); err == nil {
				return p
			}
		}
	}
	return ""
}

// ExternalPlay 用外部/旁路播放器打开 URL（供 Flutter 切到 outie#* 时调用）。
func ExternalPlay(url, name string) error {
	url = strings.TrimSpace(url)
	name = strings.ToLower(strings.TrimSpace(name))
	if url == "" {
		return fmt.Errorf("empty url")
	}
	if name == "" {
		name = "mpv"
	}
	return playSidecar(name, url, "")
}

// Available 返回当前机器上可用的播放器说明（设置页展示用）。
func Available() map[string]bool {
	return map[string]bool{
		"vlc":       findPlayer("vlc") != "" || appExists("VLC"),
		"mpv":       findPlayer("mpv") != "",
		"iina":      appExists("IINA"),
		"embed_fvp": true,
		// Flutter 页内 MPV 走 media_kit 自带 libmpv，不依赖 runtime/libmpv。
		"embed_mpv": true,
	}
}

func isEd2k(u string) bool {
	u = strings.ToLower(strings.TrimSpace(u))
	return strings.HasPrefix(u, "ed2k:")
}

func isTorrentLike(u string) bool {
	return thunder.Match(u) || isEd2k(u)
}

func openSystemURL(u string) error {
	switch runtime.GOOS {
	case "darwin":
		return exec.Command("open", u).Start()
	case "windows":
		return exec.Command("rundll32", "url.dll,FileProtocolHandler", u).Start()
	default:
		return exec.Command("xdg-open", u).Start()
	}
}
