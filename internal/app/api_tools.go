package app

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"strings"
	"time"

	"github.com/bobo/KOTV/internal/auth"
	"github.com/bobo/KOTV/internal/backup"
	"github.com/bobo/KOTV/internal/btstream"
	"github.com/bobo/KOTV/internal/cacheclean"
	"github.com/bobo/KOTV/internal/cast"
	"github.com/bobo/KOTV/internal/clientsession"
	"github.com/bobo/KOTV/internal/config"
	"github.com/bobo/KOTV/internal/database"
	"github.com/bobo/KOTV/internal/dlna"
	"github.com/bobo/KOTV/internal/hostclient"
	"github.com/bobo/KOTV/internal/localproxy"
	"github.com/bobo/KOTV/internal/player/embed"
	"github.com/bobo/KOTV/internal/playproxy"
	"github.com/bobo/KOTV/internal/remote"
	"github.com/bobo/KOTV/internal/server"
	"github.com/bobo/KOTV/internal/service"
	"github.com/bobo/KOTV/internal/settings"
	"github.com/bobo/KOTV/internal/smbproxy"
	"github.com/bobo/KOTV/internal/spider"
	"github.com/bobo/KOTV/internal/subtitle"
	"github.com/bobo/KOTV/internal/update"
	"github.com/bobo/KOTV/internal/util"
)

// APITools Flutter 设置页工具动作（备份/爬虫/更新/同步/投屏等）。
func (a *App) APITools(action string, params map[string]any) (map[string]any, error) {
	action = strings.TrimSpace(strings.ToLower(action))
	if params == nil {
		params = map[string]any{}
	}
	switch action {
	case "checkupdate":
		return a.toolCheckUpdate()
	case "spiderlist":
		return a.toolSpiderList()
	case "checkspider":
		return a.toolCheckSpider(strParam(params, "key"))
	case "setspidersdisabled":
		return a.toolSetSpidersDisabled(strListParam(params, "keys"), boolParam(params, "disabled", true))
	case "resetpair":
		if hostclient.DataOwner() != "" {
			return nil, fmt.Errorf("远端会话不能重置配对码")
		}
		code := settings.ResetSyncPairCode()
		_ = settings.Save()
		return map[string]any{"ok": true, "pairCode": code, "message": "新配对码: " + code}, nil
	case "syncsend":
		return a.toolSyncSend(
			strParam(params, "host"),
			strParam(params, "pair"),
			strParam(params, "type"),
		)
	case "backupexport":
		return a.toolBackupExport(params)
	case "backupimport":
		return a.toolBackupImport(strParam(params, "path"))
	case "castdiscover":
		return a.toolCastDiscover()
	case "castdevices":
		return a.toolCastDevices()
	case "cast":
		idx := intParam(params, "index", -1)
		return a.toolCast(idx, params)
	case "caststatus":
		return a.toolCastStatus()
	case "caststop":
		return a.toolCastStop()
	case "clearcache":
		return a.toolClearCache(params)
	case "assrtsearch":
		return a.toolAssrtSearch(strParam(params, "q"), intParam(params, "limit", 15))
	case "assrtdetail":
		id := int64(intParam(params, "id", 0))
		return a.toolAssrtDetail(id)
	case "assrtdownload":
		return a.toolAssrtDownload(strParam(params, "url"), strParam(params, "name"), strParam(params, "size"))
	default:
		return nil, fmt.Errorf("unknown action: %s", action)
	}
}

// clearVolatileMemory 清理缓存时同步丢掉可再生的进程内表（磁盘已由 cacheclean 处理）。
func (a *App) clearVolatileMemory(opt cacheclean.Options) {
	dropSites := func() {
		if a.Sites != nil {
			a.Sites.DropContentCache()
		}
		if a.sessions != nil {
			a.sessions.ForEach(func(sess *clientsession.Session) {
				if sess != nil && sess.Sites != nil {
					sess.Sites.DropContentCache()
				}
			})
		}
	}
	if opt.Other {
		server.ClearImageCache()
		util.ClearInsecureRedirectMap()
		util.ClearAllHTTPAuth()
		spider.ClearJSRedirectMap()
		playproxy.Clear()
		smbproxy.Clear()
		a.liveLoadCachedKey = ""
		a.liveLoadCached = nil
		dropSites()
	}
	if opt.Magnet {
		btstream.ClearEntries()
	}
	if (opt.Script || opt.Jar) && !opt.Other {
		dropSites()
	}
}

func (a *App) toolAssrtSearch(q string, limit int) (map[string]any, error) {
	items, err := subtitle.Search(q, limit)
	if err != nil {
		return nil, err
	}
	list := make([]map[string]any, 0, len(items))
	for _, it := range items {
		list = append(list, map[string]any{
			"id":         it.ID,
			"title":      it.DisplayTitle(),
			"nativeName": it.NativeName,
			"videoName":  it.VideoName,
			"subtype":    it.Subtype,
			"lang":       it.LangDesc,
			"site":       it.Site,
		})
	}
	return map[string]any{"ok": true, "items": list, "count": len(list)}, nil
}

func (a *App) toolAssrtDetail(id int64) (map[string]any, error) {
	if id <= 0 {
		return nil, fmt.Errorf("无效字幕 ID")
	}
	files, err := subtitle.DetailFiles(id)
	if err != nil {
		return nil, err
	}
	list := make([]map[string]any, 0, len(files))
	for _, f := range files {
		list = append(list, map[string]any{
			"name": f.Name,
			"url":  f.URL,
			"size": f.Size,
		})
	}
	return map[string]any{"ok": true, "files": list}, nil
}

func (a *App) toolAssrtDownload(url, name, size string) (map[string]any, error) {
	path, err := subtitle.DownloadToCache(subtitle.FileEntry{URL: url, Name: name, Size: size})
	if err != nil {
		return nil, err
	}
	return map[string]any{"ok": true, "path": path, "message": "字幕已下载"}, nil
}

func (a *App) toolClearCache(params map[string]any) (map[string]any, error) {
	if hostclient.DedicatedRuntime() && !currentRequestIsAdmin() {
		return nil, fmt.Errorf("%w", ErrNeedAdmin)
	}
	opt := cacheclean.Options{
		Script: boolParam(params, "script", true),
		Jar:    boolParam(params, "jar", true),
		Magnet: boolParam(params, "magnet", true),
		Logs:   boolParam(params, "logs", true),
		Other:  boolParam(params, "other", true),
	}
	res := cacheclean.Run(opt)
	a.clearVolatileMemory(opt)
	msg := fmt.Sprintf("已清理 %s", res.FreedHuman)
	if len(res.Cleared) > 0 {
		msg += "（" + strings.Join(res.Cleared, "、") + "）"
	}
	if len(res.Errors) > 0 {
		msg += "；部分失败: " + strings.Join(res.Errors, "; ")
	}

	reloaded := false
	if opt.Script || opt.Jar {
		// 爬虫包清掉后必须重载配置，重新下载 JAR / 拉站源；LoadJar 同步 parseJar。
		// ReloadConfig 以 settings.VOD 为准；远端多会话源可能不同，先记下再按会话地址重拉。
		snaps := a.snapshotSessionSources()
		var restoreErr error
		err := spider.WithSyncLoadJar(func() error {
			rerr := a.ReloadConfig()
			if len(snaps) > 0 {
				restoreErr = a.restoreSessionSources(snaps)
			}
			return rerr
		})
		if err != nil {
			msg += "；重载源失败: " + err.Error()
			res.Errors = append(res.Errors, "reload: "+err.Error())
		}
		if restoreErr != nil {
			msg += "；重新拉取当前源失败: " + restoreErr.Error()
			res.Errors = append(res.Errors, "session: "+restoreErr.Error())
		}
		if len(snaps) > 0 {
			reloaded = restoreErr == nil
		} else {
			reloaded = err == nil
		}
		if reloaded {
			msg += "；已重新拉取点播源"
		}
	}

	out := map[string]any{
		"ok":         true,
		"message":    msg,
		"freedBytes": res.FreedBytes,
		"freedHuman": res.FreedHuman,
		"cleared":    res.Cleared,
		"details":    res.Details,
		"reloaded":   reloaded,
	}
	if len(res.Errors) > 0 {
		out["errors"] = res.Errors
	}
	return out, nil
}

// boolParam 请求参数里的布尔：bool、数字、字符串（1/true/yes/on 与 0/false/no/off）都认，其它用 def。
func boolParam(m map[string]any, key string, def bool) bool {
	v, ok := m[key]
	if !ok || v == nil {
		return def
	}
	switch t := v.(type) {
	case bool:
		return t
	case string:
		s := strings.TrimSpace(strings.ToLower(t))
		if s == "0" || s == "false" || s == "no" || s == "off" {
			return false
		}
		if s == "1" || s == "true" || s == "yes" || s == "on" {
			return true
		}
	case float64:
		return t != 0
	case int:
		return t != 0
	}
	return def
}

func (a *App) toolCheckUpdate() (map[string]any, error) {
	info, err := update.Check(settings.Get(settings.UpdateURL))
	if err != nil {
		return nil, err
	}
	out := map[string]any{
		"ok":      true,
		"current": update.CurrentVersion,
		"newer":   false,
	}
	if info == nil {
		out["message"] = "已是最新版本 " + update.CurrentVersion
		return out, nil
	}
	out["newer"] = true
	out["version"] = info.Version
	out["notes"] = info.Notes
	out["message"] = "发现新版本 " + info.Version
	return out, nil
}

// spiderScope 当前会话的配置；未就绪时报错。
func (a *App) spiderScope() (*config.Manager, error) {
	cfg, ready := a.scopeReady()
	if !ready {
		return nil, fmt.Errorf("配置未就绪")
	}
	return cfg, nil
}

// toolSpiderList 检测爬虫弹窗的站源列表（含已禁用）。
func (a *App) toolSpiderList() (map[string]any, error) {
	cfg, err := a.spiderScope()
	if err != nil {
		return nil, err
	}
	sites := cfg.SitesWithDisabled()
	out := make([]map[string]any, 0, len(sites))
	for _, s := range sites {
		out = append(out, map[string]any{
			"key":      s.Key,
			"name":     s.Name,
			"disabled": s.Disabled,
		})
	}
	return map[string]any{"ok": true, "sites": out, "checkable": requireLocalCrawler() == nil}, nil
}

// toolCheckSpider 检测单个站源：首页能取到即通过。
func (a *App) toolCheckSpider(key string) (map[string]any, error) {
	if err := requireLocalCrawler(); err != nil {
		return nil, err
	}
	cfg, err := a.spiderScope()
	if err != nil {
		return nil, err
	}
	if key == "" {
		return nil, fmt.Errorf("missing key")
	}
	site := cfg.GetSite(key)
	if site == nil {
		return nil, fmt.Errorf("站源不存在: %s", key)
	}
	out := map[string]any{"ok": true, "key": site.Key, "pass": true, "message": ""}
	// 用 SpiderOnly：检测是多站并发，Spider() 会把本站记为当前站并关掉其它 js/py 实例，
	// 导致并发检测互相中断，还会顶掉首页正在用的脚本站。
	if _, err := cfg.SpiderOnly(*site).HomeContent(true); err != nil {
		out["pass"] = false
		out["message"] = err.Error()
	}
	return out, nil
}

func (a *App) toolSetSpidersDisabled(keys []string, disabled bool) (map[string]any, error) {
	cfg, err := a.spiderScope()
	if err != nil {
		return nil, err
	}
	if len(keys) == 0 {
		return nil, fmt.Errorf("missing keys")
	}
	if err := cfg.SetSitesDisabled(keys, disabled); err != nil {
		return nil, err
	}
	return map[string]any{"ok": true}, nil
}

func (a *App) toolSyncSend(host, pair, syncType string) (map[string]any, error) {
	host = strings.TrimSpace(host)
	pair = strings.TrimSpace(pair)
	syncType = strings.TrimSpace(syncType)
	if host == "" {
		return nil, fmt.Errorf("IP 不能为空")
	}
	if pair == "" {
		return nil, fmt.Errorf("配对码不能为空")
	}
	if syncType != "history" && syncType != "keep" {
		return nil, fmt.Errorf("无效同步类型")
	}
	if a.DB == nil {
		return nil, fmt.Errorf("库未就绪")
	}
	owner := hostclient.DataOwner()
	var body []byte
	var err error
	switch syncType {
	case "history":
		items, e := a.DB.ListAllHistory(owner)
		if e != nil {
			return nil, e
		}
		for i := range items {
			items[i].Key = database.ExternalHistoryKey(items[i].Key)
		}
		body, err = json.Marshal(items)
	case "keep":
		items, e := a.DB.ListAllKeep(owner, database.KeepTypeVod)
		if e != nil {
			return nil, e
		}
		body, err = json.Marshal(items)
	}
	if err != nil {
		return nil, err
	}
	if err := sendSyncData(host, pair, syncType, 1, body); err != nil {
		return nil, err
	}
	label := "历史"
	if syncType == "keep" {
		label = "收藏"
	}
	return map[string]any{"ok": true, "message": "已发送" + label}, nil
}

func (a *App) toolBackupExport(params map[string]any) (map[string]any, error) {
	if hostclient.DedicatedRuntime() && !currentRequestIsAdmin() {
		return nil, fmt.Errorf("%w", ErrNeedAdmin)
	}
	path := strParam(params, "path")
	if path == "" {
		return nil, fmt.Errorf("请指定备份路径")
	}
	data, err := backup.Export(a.DB)
	if err != nil {
		return nil, err
	}
	if err := os.WriteFile(path, data, 0o644); err != nil {
		return nil, err
	}
	return map[string]any{"ok": true, "path": path, "message": "备份已导出"}, nil
}

func (a *App) toolBackupImport(path string) (map[string]any, error) {
	if hostclient.DedicatedRuntime() && !currentRequestIsAdmin() {
		return nil, fmt.Errorf("%w", ErrNeedAdmin)
	}
	path = strings.TrimSpace(path)
	if path == "" {
		return nil, fmt.Errorf("请指定备份文件")
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	if len(data) > 32<<20 {
		return nil, fmt.Errorf("备份文件过大")
	}
	if _, err := backup.Import(a.DB, data); err != nil {
		return nil, err
	}
	a.SyncDLNARenderer()
	return map[string]any{
		"ok":      true,
		"message": "备份已恢复",
	}, nil
}

// toolCastDiscover 后台开始搜索投屏设备并立即返回；结果用 castDevices 轮询（搜到一台出一台）。
// 再次调用会作废上一轮搜索。真正投送时再校验 MediaURL。
func (a *App) toolCastDiscover() (map[string]any, error) {
	a.castMu.Lock()
	a.castGen++
	gen := a.castGen
	a.castDevs = nil
	a.castErr = ""
	a.castSearching = true
	a.castMu.Unlock()
	go func() {
		_, err := cast.DiscoverEach(4*time.Second, func(d cast.Device) {
			a.castMu.Lock()
			if a.castGen == gen {
				a.castDevs = append(a.castDevs, d)
			}
			a.castMu.Unlock()
		})
		a.castMu.Lock()
		if a.castGen == gen {
			a.castSearching = false
			if err != nil {
				a.castErr = err.Error()
			}
		}
		a.castMu.Unlock()
	}()
	return map[string]any{"ok": true}, nil
}

// toolCastDevices 当前已发现的设备；searching 为假表示本轮搜索已结束，
// 一台没搜到且出错时 error 带原因。
func (a *App) toolCastDevices() (map[string]any, error) {
	a.castMu.Lock()
	devs := append([]cast.Device(nil), a.castDevs...)
	searching := a.castSearching
	searchErr := a.castErr
	a.castMu.Unlock()
	list := make([]map[string]any, 0, len(devs))
	for i, d := range devs {
		list = append(list, map[string]any{
			"index":    i,
			"name":     d.Name,
			"protocol": string(d.Protocol),
			"detail":   d.Detail,
			"label":    d.Label(),
		})
	}
	return map[string]any{"ok": true, "devices": list, "searching": searching, "searchError": searchErr}, nil
}

func (a *App) toolCast(index int, params map[string]any) (map[string]any, error) {
	a.castMu.Lock()
	devs := a.castDevs
	a.castMu.Unlock()
	if index < 0 || index >= len(devs) {
		return nil, fmt.Errorf("请先搜索设备并选择有效项")
	}
	mediaURL := a.MediaURL()
	if mediaURL == "" {
		return nil, fmt.Errorf("请先播放内容再投屏")
	}
	// Flutter 播放器进度优先；其次 embed；再读本机媒体快照。
	posMs := int64(intParam(params, "positionMs", 0))
	if posMs <= 0 {
		posMs = embed.Active().PositionMs()
	}
	if posMs <= 0 {
		if snap := remote.SnapshotMediaFromStore(); snap != nil {
			if v := strings.TrimSpace(snap["position"]); v != "" {
				var n int64
				_, _ = fmt.Sscanf(v, "%d", &n)
				if n > 0 {
					posMs = n
				}
			}
		}
	}
	castURL, headers := playproxy.Resolve(mediaURL)
	if castURL == "" {
		castURL = mediaURL
	}
	// 需要自定义 Header 时：投本机/对外代理地址，由引擎代拉（Chromecast 无法带 Header）。
	if len(headers) > 0 {
		castURL = mediaURL
		headers = nil
	}
	castURL = playproxy.PublicizeURL(castURL)
	// 电视无法访问本机回环：改成局域网 IP；失败则禁止投屏。电视不能登录，本引擎媒体地址带上媒体钥匙。
	castURL = dlna.RewriteLocalURL(castURL)
	if dlna.IsLoopbackMediaURL(castURL) {
		return nil, fmt.Errorf("无法获取局域网 IP，投屏地址仍是本机回环，电视无法拉流")
	}
	castURL = playproxy.WithMediaKey(castURL, auth.MediaKey())
	title := a.MediaTitle()
	opt := cast.CastOptions{
		Title:      title,
		Headers:    headers,
		PositionMs: posMs,
	}
	if devs[index].Protocol == cast.ProtocolApp {
		opt.ConfigJSON = a.castConfigJSON()
		opt.DeviceJSON = a.castDeviceJSON()
		opt.HistoryJSON = a.castHistoryJSON(castURL, title, posMs)
	}
	used, err := cast.CastWithOpts(devs[index], castURL, opt)
	if err != nil {
		return nil, err
	}
	sess := cast.SessionFromDevice(used)
	cast.SetSession(sess)
	return map[string]any{
		"ok":       true,
		"name":     used.Name,
		"protocol": string(used.Protocol),
		"detail":   used.Detail,
		"label":    used.Label(),
		"key":      sess.Key(),
		"message":  "已投屏到 " + used.Label(),
	}, nil
}

func (a *App) toolCastStatus() (map[string]any, error) {
	st := cast.ProbeSession()
	out := map[string]any{
		"ok":     true,
		"active": st.Active,
	}
	if st.Active {
		out["name"] = st.Name
		out["protocol"] = string(st.Protocol)
		out["detail"] = st.Detail
		out["label"] = st.Label
		out["key"] = st.Key
		out["state"] = st.State
	}
	return out, nil
}

func (a *App) toolCastStop() (map[string]any, error) {
	err := cast.StopSession()
	if err != nil {
		// 已尽力清会话；仍回报文案供 UI。
		return map[string]any{
			"ok":      true,
			"active":  false,
			"message": "已断开投屏（对端可能未响应：" + err.Error() + "）",
		}, nil
	}
	return map[string]any{
		"ok":      true,
		"active":  false,
		"message": "已断开投屏",
	}, nil
}

func (a *App) castConfigJSON() string {
	src := strings.TrimSpace(settings.Get(settings.VOD))
	b, err := json.Marshal(map[string]string{"url": src})
	if err != nil {
		return ""
	}
	return string(b)
}

func (a *App) castDeviceJSON() string {
	ip := strings.TrimSpace(util.LanIP())
	addr := ip
	if addr != "" && !strings.Contains(addr, "://") {
		addr = fmt.Sprintf("http://%s:%d", addr, localproxy.DefaultPort)
	}
	b, err := json.Marshal(map[string]any{
		"name": "KO影视",
		"ip":   addr,
		"uuid": settings.EnsureDeviceUUID(),
		"type": 1,
	})
	if err != nil {
		return ""
	}
	return string(b)
}

func (a *App) castHistoryJSON(episodeURL, title string, posMs int64) string {
	title = strings.TrimSpace(title)
	if title == "" {
		title = "投屏播放"
	}
	episodeURL = strings.TrimSpace(episodeURL)
	// 当前播放直链投屏：push_agent + URL（兼容对端 @@@ 解析）。
	key := service.PushAgentKey + "@@@" + episodeURL + "@@@0"
	if episodeURL == "" {
		key = service.PushAgentKey + "@@@" + title + "@@@0"
	}
	b, err := json.Marshal(map[string]any{
		"key":        key,
		"vodName":    title,
		"vodPic":     "",
		"vodFlag":    "推送",
		"vodRemarks": "1",
		"episodeUrl": episodeURL,
		"position":   posMs,
		"duration":   0,
		"speed":      1.0,
	})
	if err != nil {
		return ""
	}
	return string(b)
}

func sendSyncData(host, pair, syncType string, mode int, body []byte) error {
	host = strings.TrimSpace(host)
	pair = strings.TrimSpace(pair)
	h, p, err := net.SplitHostPort(host)
	if err != nil {
		h = host
		p = fmt.Sprintf("%d", localproxy.DefaultPort)
	}
	addr := net.JoinHostPort(h, p)
	url := fmt.Sprintf("http://%s/action?do=sync&type=%s&mode=%d&pair=%s", addr, syncType, mode, pair)
	req, err := http.NewRequest(http.MethodPost, url, bytes.NewReader(body))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json")
	client := &http.Client{Timeout: 30 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		b, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
		if len(b) > 0 {
			return fmt.Errorf("%s", strings.TrimSpace(string(b)))
		}
		return fmt.Errorf("HTTP %d", resp.StatusCode)
	}
	return nil
}

func strParam(m map[string]any, key string) string {
	v, ok := m[key]
	if !ok || v == nil {
		return ""
	}
	return strings.TrimSpace(fmt.Sprint(v))
}

// strListParam JSON 数组参数转字符串列表（去空）。
func strListParam(m map[string]any, key string) []string {
	raw, _ := m[key].([]any)
	out := make([]string, 0, len(raw))
	for _, v := range raw {
		if v == nil {
			continue
		}
		if s := strings.TrimSpace(fmt.Sprint(v)); s != "" {
			out = append(out, s)
		}
	}
	return out
}

func intParam(m map[string]any, key string, def int) int {
	v, ok := m[key]
	if !ok || v == nil {
		return def
	}
	switch t := v.(type) {
	case float64:
		return int(t)
	case int:
		return t
	case json.Number:
		n, _ := t.Int64()
		return int(n)
	default:
		var n int
		_, _ = fmt.Sscanf(fmt.Sprint(v), "%d", &n)
		return n
	}
}
