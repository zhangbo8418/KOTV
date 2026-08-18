package service

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"path"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/bobo/KOTV/internal/config"
	"github.com/bobo/KOTV/internal/hostclient"
	"github.com/bobo/KOTV/internal/model"
	"github.com/bobo/KOTV/internal/parse"
	"github.com/bobo/KOTV/internal/spider"
	"github.com/bobo/KOTV/internal/thunder"
	"github.com/bobo/KOTV/internal/util"
	"golang.org/x/sync/singleflight"
)

// PushAgentKey SiteApi.PUSH：无站点配置时的推送入口。
const PushAgentKey = "push_agent"

// SiteService 站点内容服务，站点内容服务。
type SiteService struct {
	cfg *config.Manager
	mu  sync.Mutex

	HomeResult   model.Result
	DetailResult model.Result
	PlayerResult model.Result
	SearchResult []model.Collect

	loadEpoch atomic.Uint64

	homeFlight singleflight.Group

	homeCacheSite string
	categoryCache map[string]model.Result
}

// ErrHomeLoadCanceled 表示换源后旧的首页加载已被作废。
var ErrHomeLoadCanceled = errors.New("首页加载已取消")

func NewSiteService(cfg *config.Manager) *SiteService {
	return &SiteService{
		cfg:          cfg,
		SearchResult: []model.Collect{model.CollectAll()},
	}
}

// InvalidateLoads 换源：作废缓存，并立刻硬杀当前所属 JVM/Py/JS（本机共享池或远端该用户）。
// 不删脚本磁盘缓存；慢站靠单次调用超时，不在换源外层死等。
func (s *SiteService) InvalidateLoads() {
	s.loadEpoch.Add(1)
	s.mu.Lock()
	s.invalidateContentCache()
	s.mu.Unlock()
	spider.RestartCallerRuntime()
}

// InvalidateHomeOnly 仅切换首页站点：清内容缓存 + 软取消当前会话，保留运行时进程。
func (s *SiteService) InvalidateHomeOnly() {
	s.loadEpoch.Add(1)
	s.mu.Lock()
	s.invalidateContentCache()
	s.mu.Unlock()
	cid := hostclient.ScopeID()
	if cid == "" {
		return
	}
	spider.InterruptJavaBridgeForClient(cid)
	spider.InterruptScriptSpidersForClient(cid)
}

// HomeLoadEpoch 返回当前加载世代，供 UI 丢弃过期结果。
func (s *SiteService) HomeLoadEpoch() uint64 {
	return s.loadEpoch.Load()
}

// SoftCancelPending 软取消当前 Scope 的 JAR/脚本请求（不杀进程）。
func (s *SiteService) SoftCancelPending() {
	cid := hostclient.ScopeID()
	if cid == "" {
		// 无会话键时 Interrupt*( "" ) 会打断全部脚本，易误杀其它窗口的 play。
		return
	}
	spider.InterruptJavaBridgeForClient(cid)
	spider.InterruptScriptSpidersForClient(cid)
}

// CancelPendingContent 硬杀当前所属 JVM/Py/JS（离开详情/卡死恢复）。
func (s *SiteService) CancelPendingContent() {
	spider.RestartCallerRuntime()
}

func (s *SiteService) HomeContent() (model.Result, error) {
	epoch := s.loadEpoch.Load()
	site := s.cfg.Home()
	s.mu.Lock()
	if s.homeCacheSite == site.Key && (len(s.HomeResult.Types) > 0 || len(s.HomeResult.List) > 0) {
		result := s.HomeResult
		s.mu.Unlock()
		return result, nil
	}
	s.mu.Unlock()

	flightKey := fmt.Sprintf("%s:%d", site.Key, epoch)
	v, err, _ := s.homeFlight.Do(flightKey, func() (interface{}, error) {
		return s.homeContentFor(site)
	})
	if s.loadEpoch.Load() != epoch {
		return model.Result{}, ErrHomeLoadCanceled
	}
	if err != nil {
		return model.Result{}, err
	}
	result := v.(model.Result)
	s.mu.Lock()
	s.HomeResult = result
	s.homeCacheSite = site.Key
	s.mu.Unlock()
	return result, nil
}

func (s *SiteService) homeContentFor(site model.Site) (model.Result, error) {
	var result model.Result
	var err error

	switch site.TypeID() {
	case 3: // Spider
		sp := s.cfg.Spider(site)
		home, herr := sp.HomeContent(true)
		if herr != nil {
			return model.Result{Success: false}, herr
		}
		result, err = decodeResult(home)
		if err != nil {
			return model.Result{Success: false}, err
		}
		if hv, herr := sp.HomeVideoContent(); herr == nil {
			extra, _ := decodeResult(hv)
			if len(extra.List) > 0 {
				result.List = extra.List
			}
		}
		applyTypes(site, &result)
	case 4:
		site, err = fetchExt(site)
		if err != nil {
			return model.Result{Success: false}, err
		}
		var body string
		body, err = siteCall(site, map[string]string{"filter": "true"})
		if err != nil {
			return model.Result{Success: false}, err
		}
		result, err = model.FromType(4, body)
		if err != nil {
			return model.Result{Success: false}, err
		}
		applyTypes(site, &result)
	case 0, 1, 2:
		// type2 与 TV 一致：非 spider 分支，JSON 解析（FromType≠0→JSON）。
		var body string
		body, err = util.HTTPGet(site.API, map[string]string(site.Header))
		if err != nil {
			return model.Result{Success: false}, err
		}
		result, err = model.FromType(site.TypeID(), body)
		if err != nil {
			return model.Result{Success: false}, err
		}
		result, err = fetchPic(site, result)
		if err != nil {
			return model.Result{Success: false}, err
		}
		applyTypes(site, &result)
	default:
		return model.Result{Success: false}, fmt.Errorf("不支持的站源类型: %d", site.TypeID())
	}

	for i := range result.List {
		result.List[i].Site = &site
	}
	return result, nil
}

func (s *SiteService) CategoryContent(tid, pg string, extend map[string]string) (model.Result, error) {
	return s.CategoryContentForSite("", tid, pg, extend)
}

// CategoryContentForSite 按站点拉分类；siteKey 空则用首页源。
// 对齐 TV TypeFragment.getKey()：进目录用条目所属站，而不是强制首页。
func (s *SiteService) CategoryContentForSite(siteKey, tid, pg string, extend map[string]string) (model.Result, error) {
	site := s.cfg.Home()
	if k := strings.TrimSpace(siteKey); k != "" {
		if found := s.cfg.GetSite(k); found != nil {
			site = *found
		}
	}
	extend = s.MergeCategoryExtend(tid, extend)

	s.mu.Lock()
	if cached, ok := s.getCategoryCache(site, tid, pg, extend); ok {
		s.mu.Unlock()
		return cached, nil
	}
	s.mu.Unlock()

	var result model.Result
	var err error
	switch site.TypeID() {
	case 3:
		sp := s.cfg.Spider(site)
		var raw string
		raw, err = sp.CategoryContent(tid, pg, true, extend)
		if err != nil {
			return model.Result{Success: false}, err
		}
		result, err = decodeResult(raw)
	case 0, 1, 2, 4:
		params := map[string]string{
			"ac": siteAC(site.TypeID()),
			"t":  tid,
			"pg": pg,
		}
		if site.TypeID() == 1 && len(extend) > 0 {
			b, _ := json.Marshal(extend)
			params["f"] = string(b)
		}
		if site.TypeID() == 4 {
			b, _ := json.Marshal(extend)
			params["ext"] = base64URLSafe(string(b))
		}
		var body string
		body, err = siteCall(site, params)
		if err != nil {
			return model.Result{Success: false}, err
		}
		result, err = model.FromType(site.TypeID(), body)
	default:
		return model.Result{Success: false}, fmt.Errorf("不支持的站源类型: %d", site.TypeID())
	}
	if err != nil {
		return model.Result{Success: false}, err
	}
	for i := range result.List {
		result.List[i].Site = &site
	}
	s.mu.Lock()
	s.putCategoryCache(site, tid, pg, extend, result)
	s.mu.Unlock()
	return result, nil
}

func (s *SiteService) DetailContent(vod model.Vod) (model.Vod, error) {
	site := vod.Site
	if site == nil {
		h := s.cfg.Home()
		site = &h
	}

	// SiteApi.detailContent：push_agent 把 id 当播放地址。
	if site.Key == PushAgentKey {
		id := vod.VodID.String()
		detail := model.Vod{
			VodID:       model.FlexString(id),
			VodName:     id,
			VodPlayURL:  id,
			VodPlayFrom: "推送",
			Site:        site,
		}
		detail.SetVodFlags()
		result := model.Result{Success: true, List: []model.Vod{detail}}
		s.mu.Lock()
		s.DetailResult = result
		s.mu.Unlock()
		return detail, nil
	}

	var result model.Result
	var err error
	switch site.TypeID() {
	case 3:
		sp := s.cfg.Spider(*site)
		var raw string
		raw, err = sp.DetailContent([]string{vod.VodID.String()})
		if err != nil {
			return vod, err
		}
		result, err = decodeResult(raw)
	case 0, 1, 2, 4:
		params := map[string]string{
			"ac":  siteAC(site.TypeID()),
			"ids": vod.VodID.String(),
		}
		var body string
		body, err = siteCall(*site, params)
		if err != nil {
			return vod, err
		}
		result, err = model.FromType(site.TypeID(), body)
	default:
		return vod, fmt.Errorf("不支持的站源类型: %d", site.TypeID())
	}
	if err != nil {
		return vod, err
	}
	if len(result.List) == 0 {
		return vod, fmt.Errorf("详情为空")
	}
	detail := result.List[0]
	detail.Site = site
	detail.SetVodFlags()
	// 磁力展开（DHT 等元数据）可能数十秒，不在详情关键路径同步执行；
	// UI 进详情后异步 ExpandVod，失败时仍保留原 magnet 链、起播再试。
	s.mu.Lock()
	s.DetailResult = result
	s.mu.Unlock()
	return detail, nil
}

// CachedDetail 返回最近一次详情（同 vodID），供磁力展开复用，避免二次爬虫冲掉 UI 弹窗。
func (s *SiteService) CachedDetail(vodID string) (model.Vod, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if len(s.DetailResult.List) == 0 {
		return model.Vod{}, false
	}
	v := s.DetailResult.List[0]
	if vodID != "" && v.VodID.String() != "" && v.VodID.String() != vodID {
		return model.Vod{}, false
	}
	return v, true
}

func (s *SiteService) PlayerContent(site model.Site, flag, id string) (model.Result, error) {
	var result model.Result
	var err error

	// push_agent 直接把 id 当 url，再走 Source.fetch。
	if site.Key == PushAgentKey {
		id = normalizePlayID(site, id)
		result = model.Result{
			Success: true,
			URL:     model.URL{URLs: []string{id}},
			Flag:    flag,
			Parse:   model.FlexInt{Valid: true, Value: 0},
		}
		applySourceFetch(&result)
	} else {
		switch site.TypeID() {
		case 3:
			// type=3 spider（JS/PY）传参阶段不强制把剧集 id 补成绝对 URL，
			// 让 spider 自己按 TV 的输入形态拼接/解析。
			sp := s.cfg.Spider(site)
			vipFlags := s.cfg.API().Flags
			var raw string
			// 此处保持 id 原样（不 normalize）
			raw, err = sp.PlayerContent(flag, id, vipFlags)
			if err != nil {
				return model.Result{Success: false}, err
			}
			result, err = decodeResult(raw)
			if err != nil {
				return model.Result{Success: false}, err
			}
			result.Key = site.Key
			// 先合并站点头，再补相对 URL（很多 JS 源 play 不带回 Referer，相对 path 依赖站点头）。
			result.Header = mergeHeaders(site.Header, result.Header)
			sanitizeResultPlayURLs(site, &result)
			applySourceFetch(&result)
		case 4:
			params := map[string]string{
				"play": id,
				"flag": flag,
			}
			var body string
			body, err = siteCall(site, params)
			if err != nil {
				return model.Result{Success: false}, err
			}
			result, err = model.FromType(4, body)
			if err != nil {
				return model.Result{Success: false}, err
			}
			result.Header = mergeHeaders(site.Header, result.Header)
			sanitizeResultPlayURLs(site, &result)
			applySourceFetch(&result)
		case 0, 1, 2:
			id = normalizePlayID(site, id)
			// 本地拼 Result，不请求 API。相对路径按站源 api 补成绝对地址再解析。
			playID := id
			parseVal := 1
			if s.IsVideoFormat(site, playID) && strings.TrimSpace(site.PlayURL) == "" {
				parseVal = 0
			}
			result = model.Result{
				Success: true,
				URL:     model.URL{URLs: []string{playID}},
				Flag:    flag,
				Header:  site.Header,
				PlayURL: site.PlayURL,
				Parse:   model.FlexInt{Valid: true, Value: parseVal},
			}
			applySourceFetch(&result)
		default:
			return model.Result{Success: false}, fmt.Errorf("不支持的站源类型: %d", site.TypeID())
		}
	}

	// Result.setHeader：仅当结果头为空时写入站点头。
	result.Header = mergeHeaders(site.Header, result.Header)
	if result.Flag == "" && flag != "" {
		result.Flag = flag
	}
	// 起播：磁力转本地 HTTP
	if err := applyThunderFetch(&result); err != nil {
		return model.Result{Success: false}, err
	}
	s.mu.Lock()
	s.PlayerResult = result
	s.mu.Unlock()
	return result, nil
}

// normalizePlayID 清洗剧集 id，并将相对路径尽量补成绝对地址（供 JS request / 二次解析使用）。
func normalizePlayID(site model.Site, id string) string {
	return resolvePlayAbsolute(id, playURLBases(site, nil)...)
}

func sanitizeResultPlayURLs(site model.Site, r *model.Result) {
	if r == nil || len(r.URL.URLs) == 0 {
		return
	}
	bases := playURLBases(site, r)
	for i, u := range r.URL.URLs {
		r.URL.URLs[i] = resolvePlayAbsolute(u, bases...)
	}
}

// playURLBases 相对播放地址的拼接基址：结果头 Referer/Origin → 站点头 → site.API。
// 日志里常见 JS 源返回 /play/xxx.html，Referer 为站点根（如 https://www.lmm85.com）。
func playURLBases(site model.Site, r *model.Result) []string {
	var bases []string
	seen := map[string]bool{}
	add := func(raw string) {
		raw = strings.TrimSpace(raw)
		if raw == "" || !strings.HasPrefix(raw, "http") || seen[raw] {
			return
		}
		seen[raw] = true
		bases = append(bases, raw)
	}
	addFromHeader := func(h map[string]string) {
		if h == nil {
			return
		}
		for _, k := range []string{"Referer", "referer", "Origin", "origin"} {
			add(h[k])
		}
	}
	if r != nil {
		addFromHeader(map[string]string(r.Header))
	}
	addFromHeader(map[string]string(site.Header))
	add(site.API)
	return bases
}

func resolvePlayAbsolute(id string, bases ...string) string {
	id = model.CleanEpisodePlayURL(id)
	if id == "" || strings.HasPrefix(id, "http://") || strings.HasPrefix(id, "https://") ||
		thunder.Match(id) || strings.HasPrefix(strings.ToLower(id), "ed2k:") {
		return id
	}
	for _, base := range bases {
		if abs := util.ResolveRelativeURL(base, id); abs != "" && abs != id &&
			(strings.HasPrefix(abs, "http://") || strings.HasPrefix(abs, "https://")) {
			return abs
		}
	}
	return id
}

// applySourceFetch Source.fetch：特殊 scheme / .strm 预处理后再二次解析/起播。
// - video:// → 剥前缀 + parse=1（逼宿主嗅探）
// - push://  → 剥前缀 + parse=0（桌面直接播内层 URL；TV 会新开 VideoActivity）
// - *.strm  → 读文本首行真实地址 + parse=0
// Force / JianPian / TVBus / Youtube 依赖 Android/Native，桌面暂不支持。
func applySourceFetch(r *model.Result) {
	if r == nil || len(r.URL.URLs) == 0 {
		return
	}
	forceParse := false
	directPlay := false
	for i, raw := range r.URL.URLs {
		u := strings.TrimSpace(raw)
		lower := strings.ToLower(u)
		switch {
		case strings.HasPrefix(lower, "video://"):
			u = strings.TrimSpace(u[len("video://"):])
			r.URL.URLs[i] = u
			forceParse = true
		case strings.HasPrefix(lower, "push://"):
			u = strings.TrimSpace(u[len("push://"):])
			r.URL.URLs[i] = u
			directPlay = true
		case strmPath(u):
			if fetched := fetchStrmURL(u); fetched != "" {
				r.URL.URLs[i] = fetched
			}
			directPlay = true
		}
	}
	switch {
	case forceParse:
		r.Parse = model.FlexInt{Valid: true, Value: 1}
	case directPlay:
		r.Parse = model.FlexInt{Valid: true, Value: 0}
	}
}

func strmPath(u string) bool {
	p := u
	if i := strings.Index(u, "?"); i >= 0 {
		p = u[:i]
	}
	if ju, err := url.Parse(u); err == nil && ju.Path != "" {
		p = ju.Path
	}
	return strings.HasSuffix(strings.ToLower(path.Base(p)), ".strm")
}

func fetchStrmURL(u string) string {
	u = strings.TrimSpace(u)
	if u == "" {
		return ""
	}
	lower := strings.ToLower(u)
	if strings.HasPrefix(lower, "http://") || strings.HasPrefix(lower, "https://") {
		return fetchStrmHTTP(u)
	}
	filePath := u
	if strings.HasPrefix(lower, "file://") {
		filePath = u[len("file://"):]
	}
	b, err := os.ReadFile(filePath)
	if err != nil {
		return u
	}
	return firstLine(string(b))
}

func fetchStrmHTTP(rawURL string) string {
	client := &http.Client{
		Timeout: 20 * time.Second,
		CheckRedirect: func(req *http.Request, via []*http.Request) error {
			return http.ErrUseLastResponse
		},
	}
	req, err := http.NewRequest(http.MethodGet, util.EncodeURL(rawURL), nil)
	if err != nil {
		return rawURL
	}
	req.Header.Set("User-Agent", "Mozilla/5.0 KOTV/1.0")
	resp, err := client.Do(req)
	if err != nil {
		return rawURL
	}
	defer resp.Body.Close()
	disp := resp.Header.Get("Content-Disposition")
	ct := strings.ToLower(resp.Header.Get("Content-Type"))
	text := strings.Contains(disp, ".strm") || strings.Contains(disp, ".txt") ||
		strings.Contains(ct, "text/") || strings.HasSuffix(strings.ToLower(path.Base(rawURL)), ".strm")
	if !text {
		return rawURL
	}
	b, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		return rawURL
	}
	line := firstLine(string(b))
	if line == "" {
		return rawURL
	}
	return line
}

func firstLine(s string) string {
	s = strings.TrimSpace(s)
	if s == "" {
		return ""
	}
	if i := strings.IndexAny(s, "\r\n"); i >= 0 {
		return strings.TrimSpace(s[:i])
	}
	return s
}

func applyThunderFetch(r *model.Result) error {
	u := ""
	if len(r.URL.URLs) > 0 {
		u = r.URL.URLs[0]
	}
	if u == "" || !thunder.Match(u) {
		return nil
	}
	local, err := thunder.Fetch(u)
	if err != nil {
		return err
	}
	r.URL = model.URL{URLs: []string{local}, Names: r.URL.Names}
	r.Parse = model.FlexInt{Valid: true, Value: 0}
	return nil
}

func (s *SiteService) Search(keyword string, siteKeys []string) ([]model.Collect, error) {
	return s.SearchParallel(keyword, siteKeys, 1)
}

// SearchParallel 多站并发搜索，maxConcurrent 为并发上限（<=0 时默认 4）。
func (s *SiteService) SearchParallel(keyword string, siteKeys []string, maxConcurrent int) ([]model.Collect, error) {
	// 宿主统一繁→简，提高繁体关键词在简体源上的命中率（与 TV SearchTask 一致）。
	keyword = spider.T2S(strings.TrimSpace(keyword))
	sites := s.cfg.Sites()
	if len(siteKeys) > 0 {
		filtered := make([]model.Site, 0)
		for _, site := range sites {
			for _, k := range siteKeys {
				if site.Key == k {
					filtered = append(filtered, site)
				}
			}
		}
		sites = filtered
	}
	searchable := make([]model.Site, 0, len(sites))
	for _, site := range sites {
		if site.IsSearchable() {
			searchable = append(searchable, site)
		}
	}
	if len(searchable) == 0 {
		collects := []model.Collect{model.CollectAll()}
		s.mu.Lock()
		s.SearchResult = collects
		s.mu.Unlock()
		return collects, nil
	}
	if maxConcurrent <= 0 {
		maxConcurrent = 4
	}
	sem := make(chan struct{}, maxConcurrent)
	type siteResult struct {
		collect model.Collect
		ok      bool
	}
	results := make([]siteResult, len(searchable))
	var wg sync.WaitGroup
	parentCID := hostclient.Current()
	parentUID := hostclient.CurrentUserID()
	parentDed := hostclient.DedicatedRuntime()
	for i, site := range searchable {
		wg.Add(1)
		go func(i int, site model.Site) {
			defer wg.Done()
			done := hostclient.EnterSession(parentCID, parentUID, parentDed)
			defer done()
			sem <- struct{}{}
			defer func() { <-sem }()
			list, err := s.searchSite(site, keyword, false, "1")
			if err != nil || len(list) == 0 {
				return
			}
			siteCopy := site
			for j := range list {
				list[j].Site = &siteCopy
			}
			results[i] = siteResult{
				collect: model.Collect{Name: site.Name, Site: &siteCopy, List: list},
				ok:      true,
			}
		}(i, site)
	}
	wg.Wait()

	var collects []model.Collect
	for _, r := range results {
		if r.ok {
			collects = append(collects, r.collect)
		}
	}
	if len(collects) == 0 {
		collects = []model.Collect{model.CollectAll()}
	}
	s.mu.Lock()
	s.SearchResult = collects
	s.mu.Unlock()
	return collects, nil
}

func (s *SiteService) searchSite(site model.Site, keyword string, quick bool, page string) ([]model.Vod, error) {
	switch site.TypeID() {
	case 3:
		sp := s.cfg.Spider(site)
		raw, err := sp.SearchContent(keyword, quick, page)
		if err != nil {
			return nil, err
		}
		result, err := decodeResult(raw)
		if err != nil {
			return nil, err
		}
		return result.List, nil
	case 0, 1, 2, 4:
		params := map[string]string{
			"wd":     keyword,
			"quick":  fmt.Sprintf("%v", quick),
			"extend": "",
		}
		if page != "" && page != "1" {
			params["pg"] = page
		}
		body, err := siteCall(site, params)
		if err != nil {
			return nil, err
		}
		result, err := model.FromType(site.TypeID(), body)
		if err != nil {
			return nil, err
		}
		result, err = fetchPic(site, result)
		if err != nil {
			return nil, err
		}
		return result.List, nil
	default:
		return nil, fmt.Errorf("不支持的站源类型: %d", site.TypeID())
	}
}

func mergeHeaders(siteHdr, resultHdr model.FlexHeader) model.FlexHeader {
	// Result.setHeader：结果已有头则保留，否则用站点头。
	if len(resultHdr) == 0 {
		return siteHdr
	}
	return resultHdr
}

// Action SiteApi.action：type3 爬虫；type4 把 action 当 URL GET；其它空。
func (s *SiteService) Action(site model.Site, action string) (string, error) {
	action = strings.TrimSpace(action)
	switch site.TypeID() {
	case 3:
		return s.cfg.Spider(site).Action(action)
	case 4:
		if action == "" {
			return "{}", nil
		}
		return util.HTTPGet(action, map[string]string(site.Header))
	default:
		return "{}", nil
	}
}

// IsVideoFormat CustomWebView.isVideoFormat：
// sniffer() 为真 → 爬虫 isVideo；否则 Sniffer.isVideoFormat（含配置 rules.regex/exclude）。
func (s *SiteService) IsVideoFormat(site model.Site, u string) bool {
	sp := s.cfg.Spider(site)
	if ok, err := sp.ManualVideoCheck(); err == nil && ok {
		if v, err := sp.IsVideoFormat(u); err == nil {
			return v
		}
	}
	rules := parse.GetRules()
	if len(rules) == 0 {
		rules = s.cfg.API().Rules
	}
	return parse.IsVideoFormatRules(u, rules)
}

func decodeResult(raw string) (model.Result, error) {
	return model.FromType(1, raw)
}
