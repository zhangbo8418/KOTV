package app

import (
	"fmt"
	"io"
	"log"
	neturl "net/url"
	"os"
	"path/filepath"
	"strings"
	"sync"

	"github.com/bobo/KOTV/internal/cast"
	"github.com/bobo/KOTV/internal/config"
	"github.com/bobo/KOTV/internal/danmaku"
	"github.com/bobo/KOTV/internal/database"
	"github.com/bobo/KOTV/internal/dlna"
	"github.com/bobo/KOTV/internal/live"
	"github.com/bobo/KOTV/internal/model"
	"github.com/bobo/KOTV/internal/paths"
	"github.com/bobo/KOTV/internal/player"
	"github.com/bobo/KOTV/internal/player/embed"
	"github.com/bobo/KOTV/internal/remote"
	appruntime "github.com/bobo/KOTV/internal/runtime"
	"github.com/bobo/KOTV/internal/server"
	"github.com/bobo/KOTV/internal/service"
	"github.com/bobo/KOTV/internal/settings"
	"github.com/bobo/KOTV/internal/spider"
	"github.com/bobo/KOTV/internal/util"
)

// App 全局应用状态。
type App struct {
	DB     *database.DB
	Config *config.Manager
	Sites  *service.SiteService
	Live   *live.Service
	Server *server.Server
	Ready  bool
	ErrMsg string

	CurrentScreen    string
	SelectedVod      *model.Vod
	PendingSearch    string
	RemoteSearchAuto bool

	// 播放失败跨站换源会话（详情页重建后仍保留）。
	fbMu      sync.Mutex
	fbFailed  map[string]bool
	fbQueue   []model.Vod
	fbRemarks string
	fbArmed   bool

	mediaMu    sync.RWMutex
	mediaState string
	mediaTitle string
	mediaURL   string

	castMu   sync.Mutex
	castDevs []cast.Device

	DanmakuToast string
}

var defaultApp *App

func Default() *App { return defaultApp }

func New() (*App, error) {
	_ = os.MkdirAll(os.TempDir(), 0o755)
	setupFileLog()
	if err := settings.Load(); err != nil {
		log.Printf("加载设置失败: %v", err)
	}
	settings.EnsureDeviceUUID()
	settings.EnsureSyncPairCode()
	util.SetProxy(settings.Get(settings.Proxy))
	spider.SetUserProxy(settings.Get(settings.Proxy))

	db, err := database.Open()
	if err != nil {
		return nil, fmt.Errorf("数据库初始化失败: %w", err)
	}

	cfg := config.NewManager(db)
	sites := service.NewSiteService(cfg)
	liveSvc := live.NewService(cfg)

	a := &App{
		DB:            db,
		Config:        cfg,
		Sites:         sites,
		Live:          liveSvc,
		CurrentScreen: "video",
		mediaState:    "idle",
	}
	defaultApp = a

	a.Server = server.New(func(action server.Action) {
		switch action.Do {
		case "danmaku":
			danmaku.PushLive(action.Text)
			a.DanmakuToast = danmaku.FormatLive(action.Text)
		}
	})
	a.Server.SetContentAPI(a)
	a.Server.SetMediaProvider(func() map[string]string {
		return remote.SnapshotMedia()
	})

	if err := a.Server.Start(); err != nil {
		log.Printf("HTTP 服务启动失败: %v", err)
	}
	a.Server.SetSyncHandler(server.NewAppSyncHandler(db, func(code string) bool {
		return code != "" && code == settings.Get(settings.SyncPairCode)
	}))

	go a.listenEvents()

	if err := cfg.InitFromSettings(); err != nil {
		a.ErrMsg = err.Error()
		log.Printf("配置加载: %v", err)
	} else {
		a.Ready = true
	}
	liveSvc.SyncFromConfig()

	if settings.IsDLNARenderer() {
		a.startDLNARenderer()
	}

	player.SetProgressHandler(func(p player.Progress) {
		if p.HistoryKey == "" || settings.IsIncognito() {
			return
		}
		_ = db.UpdateHistoryProgress(p.HistoryKey, p.PositionMs, p.DurationMs)
	})

	st := appruntime.Status()
	log.Printf("运行时[%s] jvm=%s python=%s chromium=%s ffmpeg=%s libvlc=%s bridge=%s",
		st["platform"], st["jvm"], st["python"], st["chromium"], st["ffmpeg"], st["libvlc"], st["bridge"])

	return a, nil
}

func (a *App) listenEvents() {
	go func() {
		for word := range a.Server.Events().SubscribeSearch() {
			a.PendingSearch = word
			a.CurrentScreen = "search"
			a.RemoteSearchAuto = true
			remote.NotifySearch(word)
		}
	}()
	go func() {
		for url := range a.Server.Events().SubscribePush() {
			a.openPushURL(url)
			remote.NotifyPush()
		}
	}()
	go func() {
		for ev := range a.Server.Events().SubscribeSetting() {
			a.applyRemoteSetting(ev.Name, ev.Value)
		}
	}()
	go func() {
		for ev := range a.Server.Events().SubscribeControl() {
			remote.NotifyControl(ev.Type, ev.SeekMs)
		}
	}()
	go func() {
		for text := range a.Server.Events().SubscribeDanmaku() {
			danmaku.PushLive(text)
			a.DanmakuToast = danmaku.FormatLive(text)
		}
	}()
	go func() {
		for ev := range a.Server.Events().SubscribeRefresh() {
			switch strings.ToLower(ev.Type) {
			case "subtitle":
				if enh, ok := embed.ActiveEnhanced(); ok && ev.Path != "" {
					_ = enh.AddSubtitleFile(ev.Path)
				}
			case "danmaku":
				path := ev.Path
				if path == "" {
					continue
				}
				if strings.HasPrefix(strings.ToLower(path), "http://") || strings.HasPrefix(strings.ToLower(path), "https://") {
					_ = danmaku.LoadURL(path)
				} else {
					_ = danmaku.LoadFile(path)
				}
			}
		}
	}()
	go func() {
		for ev := range a.Server.Events().SubscribeCast() {
			a.ApplyRemoteCast(ev.Config, ev.History)
		}
	}()
}

func (a *App) applyRemoteSetting(name, value string) {
	value = strings.TrimSpace(value)
	if value == "" {
		return
	}
	name = strings.ToLower(strings.TrimSpace(name))
	switch name {
	case "", "vod":
		settings.Set(settings.VOD, value)
	case "live":
		settings.Set(settings.LIVE, value)
	default:
		settings.Set(settings.Type(name), value)
	}
	_ = settings.Save()
	_ = a.ReloadConfig()
}

func (a *App) ReloadConfig() error {
	util.SetProxy(settings.Get(settings.Proxy))
	spider.SetUserProxy(settings.Get(settings.Proxy))
	a.Config.Clear()
	if err := a.Config.InitFromSettings(); err != nil {
		a.Ready = false
		a.ErrMsg = err.Error()
		return err
	}
	a.Ready = true
	a.ErrMsg = ""
	a.Live.SyncFromConfig()
	return nil
}

// LoadVodSource 从 URL 或 JSON 正文加载点播配置。
func (a *App) LoadVodSource(source string) error {
	util.SetProxy(settings.Get(settings.Proxy))
	spider.SetUserProxy(settings.Get(settings.Proxy))
	a.Config.Clear()
	if err := a.Config.LoadFromSource(source); err != nil {
		a.Ready = false
		a.ErrMsg = err.Error()
		return err
	}
	a.Ready = true
	a.ErrMsg = ""
	a.Live.SyncFromConfig()
	return nil
}

func (a *App) OpenPushURL(url string) {
	a.openPushURL(url)
}

func (a *App) openPushURL(url string) {
	url = strings.TrimSpace(url)
	url = strings.TrimPrefix(url, "file://")
	if !server.MatchPushURL(url) {
		return
	}
	name := "推送播放"
	play := url
	if filepath.IsAbs(url) || (!strings.Contains(url, "://") && strings.Contains(url, string(os.PathSeparator))) {
		if abs, err := filepath.Abs(url); err == nil {
			play = abs
			name = filepath.Base(abs)
		}
	} else if u, err := neturl.Parse(url); err == nil && u.Scheme == "" {
		name = filepath.Base(url)
	} else if u, err := neturl.Parse(url); err == nil && u.Path != "" {
		if base := filepath.Base(u.Path); base != "" && base != "/" && base != "." {
			name = base
		}
	}
	vod := model.Vod{
		VodID:   model.FlexString(play),
		VodName: name,
		VodTag:  "file",
		VodFlags: []model.Flag{{
			Flag: "本地",
			Show: "本地",
			Episodes: []model.Episode{
				model.CreateEpisode(name, play),
			},
		}},
	}
	vod.SetCurrentFlag(0)
	a.SelectedVod = &vod
	a.CurrentScreen = "detail"
}

func (a *App) Shutdown() {
	a.Sites.InvalidateLoads()
	dlna.StopRenderer()
	player.Stop()
	a.Server.Stop()
	_ = settings.Save()
	_ = a.DB.Close()
}

// SyncDLNARenderer 按设置启停被投端。
func (a *App) SyncDLNARenderer() {
	if settings.IsDLNARenderer() {
		a.startDLNARenderer()
		return
	}
	dlna.StopRenderer()
}

func (a *App) startDLNARenderer() {
	err := dlna.StartRendererHooks(dlna.RendererHooks{
		OnURI: func(uri string) {
			a.OpenPushURL(uri)
			remote.NotifyPush()
		},
		OnStop: func() {
			remote.NotifyControl("stop", 0)
		},
		OnPause: func(pause bool) {
			if pause {
				remote.NotifyControl("pause", 0)
			} else {
				remote.NotifyControl("play", 0)
			}
		},
		OnSeek: func(ms int64) {
			remote.NotifyControl("seek", ms)
		},
		OnNext: func() {
			remote.NotifyControl("next", 0)
		},
		State: func() dlna.MediaState {
			st := dlna.MediaState{URI: a.MediaURL(), State: "NO_MEDIA_PRESENT"}
			eng := embed.Active()
			if eng == nil {
				return st
			}
			st.PosMs = eng.PositionMs()
			st.DurMs = eng.DurationMs()
			switch {
			case eng.IsPlaying():
				st.State = "PLAYING"
			case st.DurMs > 0 || st.PosMs > 0:
				st.State = "PAUSED_PLAYBACK"
			case st.URI != "":
				st.State = "STOPPED"
			}
			return st
		},
	})
	if err != nil {
		log.Printf("DLNA DMR 启动失败: %v", err)
	}
}

func (a *App) SetMediaPlaying(title, url string) {
	a.mediaMu.Lock()
	a.mediaState = "playing"
	a.mediaTitle = title
	a.mediaURL = url
	a.mediaMu.Unlock()
}

func (a *App) SetMediaIdle() {
	a.mediaMu.Lock()
	a.mediaState = "idle"
	a.mediaTitle = ""
	a.mediaURL = ""
	a.mediaMu.Unlock()
}

func (a *App) MediaURL() string {
	a.mediaMu.RLock()
	defer a.mediaMu.RUnlock()
	return a.mediaURL
}

func (a *App) MediaTitle() string {
	a.mediaMu.RLock()
	defer a.mediaMu.RUnlock()
	return a.mediaTitle
}

func vodFallbackKey(siteKey, vodID string) string {
	return siteKey + "@" + vodID
}

// ClearVodFallback 清除跨站换源会话（用户手动进详情时调用）。
func (a *App) ClearVodFallback() {
	a.fbMu.Lock()
	defer a.fbMu.Unlock()
	a.fbFailed = nil
	a.fbQueue = nil
	a.fbRemarks = ""
	a.fbArmed = false
}

// VodFallbackArmed 是否正携带自动换源播放意图。
func (a *App) VodFallbackArmed() bool {
	a.fbMu.Lock()
	defer a.fbMu.Unlock()
	return a.fbArmed
}

// MarkVodFallbackFailed 记录当前片源已失败。
func (a *App) MarkVodFallbackFailed(siteKey, vodID string) {
	a.fbMu.Lock()
	defer a.fbMu.Unlock()
	if a.fbFailed == nil {
		a.fbFailed = map[string]bool{}
	}
	a.fbFailed[vodFallbackKey(siteKey, vodID)] = true
}

// IsVodFallbackFailed 是否已在本轮换源中失败过。
func (a *App) IsVodFallbackFailed(siteKey, vodID string) bool {
	a.fbMu.Lock()
	defer a.fbMu.Unlock()
	return a.fbFailed[vodFallbackKey(siteKey, vodID)]
}

// SetVodFallbackQueue 写入待切换的站源队列，并记下续播集名。
func (a *App) SetVodFallbackQueue(items []model.Vod, remarks string) {
	a.fbMu.Lock()
	defer a.fbMu.Unlock()
	a.fbQueue = append([]model.Vod(nil), items...)
	a.fbRemarks = remarks
}

// PopVodFallback 取出下一个候选站源并武装自动播放。
func (a *App) PopVodFallback() (model.Vod, string, bool) {
	a.fbMu.Lock()
	defer a.fbMu.Unlock()
	for len(a.fbQueue) > 0 {
		item := a.fbQueue[0]
		a.fbQueue = a.fbQueue[1:]
		siteKey := ""
		if item.Site != nil {
			siteKey = item.Site.Key
		}
		if a.fbFailed[vodFallbackKey(siteKey, item.VodID.String())] {
			continue
		}
		a.fbArmed = true
		return item, a.fbRemarks, true
	}
	a.fbArmed = false
	return model.Vod{}, "", false
}

// TakeVodFallbackPlay 详情页加载后消费一次自动播放意图，返回续播集名。
func (a *App) TakeVodFallbackPlay() (remarks string, ok bool) {
	a.fbMu.Lock()
	defer a.fbMu.Unlock()
	if !a.fbArmed {
		return "", false
	}
	a.fbArmed = false
	return a.fbRemarks, true
}

func (a *App) LoadDanmaku(url string) {
	go func() {
		if err := danmaku.LoadURL(url); err != nil {
			log.Printf("弹幕加载失败: %v", err)
		}
	}()
}

// PlayURL 统一播放入口。
func PlayURL(url string) error {
	return player.Play(url, "")
}

// PlayURLWithHistory 播放并绑定历史 key 以便续播写入。
func PlayURLWithHistory(url, histKey string) error {
	return player.Play(url, histKey)
}

// PlayExternal 兼容旧调用。
func PlayExternal(url string) error {
	return PlayURL(url)
}

// setupFileLog 同时写 stderr 与 ~/Library/Caches/KOTV/data/log/kotv.log，方便排障。
func setupFileLog() {
	dir := paths.LogDir()
	f, err := os.OpenFile(filepath.Join(dir, "kotv.log"), os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o644)
	if err != nil {
		log.Printf("无法打开日志文件: %v", err)
		return
	}
	log.SetOutput(io.MultiWriter(os.Stderr, f))
	log.SetFlags(log.LstdFlags | log.Lmicroseconds)
	log.Printf("日志文件: %s", filepath.Join(dir, "kotv.log"))
}
