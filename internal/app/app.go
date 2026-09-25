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

	"github.com/bobo/KOTV/internal/auth"
	"github.com/bobo/KOTV/internal/cast"
	"github.com/bobo/KOTV/internal/clientsession"
	"github.com/bobo/KOTV/internal/config"
	"github.com/bobo/KOTV/internal/danmaku"
	"github.com/bobo/KOTV/internal/database"
	"github.com/bobo/KOTV/internal/dlna"
	"github.com/bobo/KOTV/internal/hostclient"
	"github.com/bobo/KOTV/internal/live"
	"github.com/bobo/KOTV/internal/model"
	"github.com/bobo/KOTV/internal/parse"
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

	sessions *clientsession.Hub
	presence *clientsession.Presence

	CurrentScreen    string
	SelectedVod      *model.Vod
	PendingSearch    string
	RemoteSearchAuto bool

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
	if err := auth.Init(); err != nil {
		log.Printf("auth init: %v", err)
	}
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
		sessions:      clientsession.NewHub(),
		CurrentScreen: "video",
		mediaState:    "idle",
	}
	a.presence = clientsession.NewPresence(func(userID string) {
		spider.KillUserRuntime(userID)
		parse.CancelUserSniffs(userID)
		a.sessions.RemoveByUser(userID)
	})
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
	a.Server.SetTvbusProvider(func() string {
		lv := a.scopeLive()
		if lv == nil {
			return server.ResolveCoreResp(config.Default().API().Lives, nil)
		}
		return server.ResolveCoreResp(append([]model.Live(nil), lv.Sources()...), lv.Current())
	})

	// 先加载点播配置再开 HTTP，避免首请求建出会话时 Cfg 仍为空、
	// 随后只换 Cfg 不换 Sites 导致长期 Get ""。
	cfg.EnsureVodFromHistory()
	if err := cfg.InitFromSettings(); err != nil {
		a.ErrMsg = err.Error()
		log.Printf("配置加载: %v", err)
	} else {
		a.Ready = true
	}
	liveSvc.SyncFromConfig()

	if err := a.Server.Start(); err != nil {
		log.Printf("HTTP 服务启动失败: %v", err)
	}
	a.Server.SetSyncHandler(server.NewAppSyncHandler(db, func(code string) bool {
		return code != "" && code == settings.Get(settings.SyncPairCode)
	}))

	go a.listenEvents()

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
	log.Printf("运行时[%s] java=%s python=%s chromium=%s ffmpeg=%s bridge=%s",
		st["platform"], st["java"], st["python"], st["chromium"], st["ffmpeg"], st["bridge"])

	return a, nil
}

// scope 返回当前 Scope 的点播配置与 SiteService。
// 无 ScopeID：用全局 App.Config（本机单前端）。
// 有 ScopeID：ephemeral 会话——可在共享的多仓/单仓列表里各自选不同当前源；脚本磁盘缓存仍全局共享。
func (a *App) scope() (cfg *config.Manager, sites *service.SiteService, sess *clientsession.Session) {
	cid := hostclient.ScopeID()
	if cid == "" {
		return a.Config, a.Sites, nil
	}
	sess = a.sessions.GetOrCreate(cid, func() *clientsession.Session {
		cloned := a.Config.CloneEphemeral()
		liveSvc := live.NewService(cloned)
		liveSvc.SyncFromConfig()
		return &clientsession.Session{
			ClientID: cid,
			Cfg:      cloned,
			Sites:    service.NewSiteService(cloned),
			Live:     liveSvc,
			Source:   settings.Get(settings.VOD),
			Ready:    a.Ready,
			ErrMsg:   a.ErrMsg,
		}
	})
	// 自愈：Cfg 被换成新 Manager 后 Sites 仍钉旧指针时，换源/换站会一直 Get ""。
	if sess.Sites == nil || sess.Sites.Config() != sess.Cfg {
		log.Printf("session %s: rebound Sites to Cfg", cid)
		bindSessionConfig(sess, sess.Cfg)
	}
	a.bootstrapSession(sess)
	return sess.Cfg, sess.Sites, sess
}

// bindSessionConfig 替换会话配置时必须同步 Sites/Live，否则换源/换站只改 Cfg，
// 内容请求仍打旧空 Manager，表现为长期 Get "": unsupported protocol scheme ""。
func bindSessionConfig(sess *clientsession.Session, cfg *config.Manager) {
	if sess == nil || cfg == nil {
		return
	}
	sess.Cfg = cfg
	sess.Sites = service.NewSiteService(cfg)
	liveSvc := live.NewService(cfg)
	liveSvc.SyncFromConfig()
	sess.Live = liveSvc
}

// bootstrapSession 首次进入时从磁盘恢复该 Scope 上次选中的点播源。
func (a *App) bootstrapSession(sess *clientsession.Session) {
	if sess == nil || sess.Bootstrapped {
		return
	}
	sess.Bootstrapped = true
	adoptGlobal := func() {
		if !a.Ready {
			return
		}
		bindSessionConfig(sess, a.Config.CloneEphemeral())
		sess.Ready = true
		sess.ErrMsg = ""
		sess.Source = settings.Get(settings.VOD)
	}
	src, homeKey := clientsession.LoadSource(sess.ClientID)
	src = strings.TrimSpace(src)
	if src == "" {
		adoptGlobal()
		return
	}
	cur := strings.TrimSpace(sess.Source)
	if cur != "" && cur == src && sess.Ready {
		return
	}
	if err := sess.Cfg.LoadFromSource(src); err != nil {
		if a.Ready {
			adoptGlobal()
			return
		}
		sess.Ready = false
		sess.ErrMsg = err.Error()
		return
	}
	sess.Source = src
	sess.Ready = true
	sess.ErrMsg = ""
	if homeKey != "" {
		if site := sess.Cfg.GetSite(homeKey); site != nil {
			sess.Cfg.SetHome(*site)
		}
	}
	if sess.Live != nil {
		sess.Live.SyncFromConfig()
	}
}

// scopeLive 当前 Scope 的直播服务（有会话则用会话内选中源）。
func (a *App) scopeLive() *live.Service {
	_, _, sess := a.scope()
	if sess != nil && sess.Live != nil {
		return sess.Live
	}
	return a.Live
}

func (a *App) savedLiveSources() []model.Live {
	var out []model.Live
	seen := map[string]struct{}{}
	if a.DB != nil {
		cfgs, err := a.DB.ListConfigs(int64(database.ConfigTypeLive))
		if err == nil {
			for _, c := range cfgs {
				url := strings.TrimSpace(c.URL)
				if url == "" {
					continue
				}
				seen[url] = struct{}{}
				out = append(out, model.Live{Name: strings.TrimSpace(c.Name), URL: url})
			}
		}
	}
	current := strings.TrimSpace(settings.Get(settings.LIVE))
	if current != "" {
		if _, ok := seen[current]; !ok {
			a.persistLiveSource(current)
			out = append([]model.Live{{Name: "", URL: current}}, out...)
		}
	}
	return out
}

func (a *App) persistLiveSource(raw string) string {
	url := config.NormalizeSource(strings.TrimSpace(raw))
	if url == "" || a.DB == nil {
		return url
	}
	if _, err := a.DB.UpsertConfig(&database.Config{
		Type: database.ConfigTypeLive,
		URL:  url,
	}); err != nil {
		log.Printf("persist live source %s: %v", url, err)
	}
	return url
}

func (a *App) syncLive() {
	if lv := a.scopeLive(); lv != nil {
		lv.SyncFromConfig()
	}
	if a.Live != nil && a.scopeLive() != a.Live {
		a.Live.SyncFromConfig()
	}
}

func (a *App) listenEvents() {
	go func() {
		for ev := range a.Server.Events().SubscribeSearch() {
			a.PendingSearch = ev.Word
			a.CurrentScreen = "search"
			a.RemoteSearchAuto = true
			remote.NotifySearch(ev.Word, ev.ClientID)
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
			remote.NotifyControl(ev.Type, ev.SeekMs, ev.ClientID)
		}
	}()
	go func() {
		for text := range a.Server.Events().SubscribeDanmaku() {
			danmaku.PushLive(text)
			a.DanmakuToast = danmaku.FormatLive(text)
			remote.DefaultQueue.PushLiveDanmaku(text, "")
		}
	}()
	go func() {
		for ev := range a.Server.Events().SubscribeRefresh() {
			switch strings.ToLower(ev.Type) {
			case "subtitle":
				if enh, ok := embed.ActiveEnhanced(); ok && ev.Path != "" {
					_ = enh.AddSubtitleFile(ev.Path)
				}
				if ev.Path != "" {
					remote.DefaultQueue.PushRefresh("subtitle", ev.Path, "")
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
				remote.DefaultQueue.PushRefresh("danmaku", path, "")
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
		url := a.persistLiveSource(value)
		settings.Set(settings.LIVE, url)
	default:
		settings.Set(settings.Type(name), value)
	}
	_ = settings.Save()
	_ = a.ReloadConfig()
}

func (a *App) ReloadConfig() error {
	util.SetProxy(settings.Get(settings.Proxy))
	spider.SetUserProxy(settings.Get(settings.Proxy))
	// 换仓前先不可用，避免 Clear 窗口内仍 Ready 去 Get ""。
	a.Ready = false
	a.ErrMsg = ""
	a.Config.Clear()
	if err := a.Config.InitFromSettings(); err != nil {
		a.ErrMsg = err.Error()
		return err
	}
	a.Ready = true
	a.ErrMsg = ""
	a.Live.SyncFromConfig()
	a.syncSessionsFromGlobal()
	return nil
}

// LoadVodSource 从 URL 或 JSON 正文加载点播配置。
func (a *App) LoadVodSource(source string) error {
	util.SetProxy(settings.Get(settings.Proxy))
	spider.SetUserProxy(settings.Get(settings.Proxy))
	a.Ready = false
	a.ErrMsg = ""
	a.Config.Clear()
	if err := a.Config.LoadFromSource(source); err != nil {
		a.ErrMsg = err.Error()
		return err
	}
	a.Ready = true
	a.ErrMsg = ""
	a.Live.SyncFromConfig()
	a.syncSessionsFromGlobal()
	return nil
}

// syncSessionsFromGlobal 全局换源成功后，会话侧整图换到新配置，避免 Cfg/Sites 仍钉旧实例。
func (a *App) syncSessionsFromGlobal() {
	if a == nil || a.sessions == nil || !a.Ready {
		return
	}
	a.sessions.ForEach(func(sess *clientsession.Session) {
		if sess == nil {
			return
		}
		bindSessionConfig(sess, a.Config.CloneEphemeral())
		sess.Ready = true
		sess.ErrMsg = ""
		sess.Source = settings.Get(settings.VOD)
	})
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
	if a.presence != nil {
		a.presence.Stop()
	}
	// 不要走 InvalidateLoads：其中 ClearJarBridgeOnSwitch 可能短暂把 JVM 再拉起来。
	spider.InterruptScriptSpiders()
	spider.InterruptJavaBridge()
	spider.ResetScriptSpiders()
	spider.ShutdownJavaBridge()
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
			remote.NotifyControl("stop", 0, "")
		},
		OnPause: func(pause bool) {
			if pause {
				remote.NotifyControl("pause", 0, "")
			} else {
				remote.NotifyControl("play", 0, "")
			}
		},
		OnSeek: func(ms int64) {
			remote.NotifyControl("seek", ms, "")
		},
		OnNext: func() {
			remote.NotifyControl("next", 0, "")
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
	_, _, sess := a.scope()
	if sess != nil {
		sess.SetMediaPlaying(title, url)
	} else {
		a.mediaMu.Lock()
		a.mediaState = "playing"
		a.mediaTitle = title
		a.mediaURL = url
		a.mediaMu.Unlock()
	}
	remote.SetMediaStore(map[string]string{
		"state": "playing",
		"title": title,
		"url":   url,
	})
}

func (a *App) SetMediaIdle() {
	_, _, sess := a.scope()
	if sess != nil {
		sess.SetMediaIdle()
	} else {
		a.mediaMu.Lock()
		a.mediaState = "idle"
		a.mediaTitle = ""
		a.mediaURL = ""
		a.mediaMu.Unlock()
	}
	remote.SetMediaStore(map[string]string{"state": "idle", "title": "未播放"})
}

func (a *App) MediaURL() string {
	_, _, sess := a.scope()
	if sess != nil {
		return sess.MediaURL()
	}
	a.mediaMu.RLock()
	defer a.mediaMu.RUnlock()
	return a.mediaURL
}

func (a *App) MediaTitle() string {
	_, _, sess := a.scope()
	if sess != nil {
		return sess.MediaTitle()
	}
	a.mediaMu.RLock()
	defer a.mediaMu.RUnlock()
	return a.mediaTitle
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

// setupFileLog 同时写 stderr 与 {Root}/data/log/kotv.log，方便排障。
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
