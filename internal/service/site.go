package service

import (
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"sync"
	"sync/atomic"

	"github.com/bobo/KOTV/internal/config"
	"github.com/bobo/KOTV/internal/hostclient"
	"github.com/bobo/KOTV/internal/model"
	"github.com/bobo/KOTV/internal/parse"
	"github.com/bobo/KOTV/internal/settings"
	"github.com/bobo/KOTV/internal/source"
	"github.com/bobo/KOTV/internal/spider"
	"github.com/bobo/KOTV/internal/thunder"
	"github.com/bobo/KOTV/internal/util"
	"golang.org/x/sync/singleflight"
)

// PushAgentKey SiteApi.PUSH：无站点配置时的推送入口。
const PushAgentKey = "push_agent"

// PushAgentPic 推送详情占位图（TV R.string.push_image 等价 data URI，1x1 JPEG）。
const PushAgentPic = "data:image/jpeg;base64,/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAgGBgcGBQgHBwcJCQgKDBQNDAsLDBkSEw8UHRofHh0aHBwgJC4nICIsIxwcKDcpLDAxNDQ0Hyc5PTgyPC4zNDL/2wBDAQkJCQwLDBgNDRgyIRwhMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjL/wAARCAABAAEDASIAAhEBAxEB/8QAFQABAQAAAAAAAAAAAAAAAAAAAAn/xAAUEAEAAAAAAAAAAAAAAAAAAAAA/8QAFQEBAQAAAAAAAAAAAAAAAAAAAAX/xAAUEQEAAAAAAAAAAAAAAAAAAAAA/9oADAMBAAIQAxAAAAGfAP/EABQQAQAAAAAAAAAAAAAAAAAAAAD/2gAIAQEAAQUCf//EABQRAQAAAAAAAAAAAAAAAAAAAAD/2gAIAQMBAT8Bf//EABQRAQAAAAAAAAAAAAAAAAAAAAD/2gAIAQIBAT8Bf//Z"

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

// Config 当前绑定的配置管理器（须与会话 Cfg 同一指针）。
func (s *SiteService) Config() *config.Manager {
	if s == nil {
		return nil
	}
	return s.cfg
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

	// 空 API 早拒，避免甩出 Get "" unsupported protocol。
	if strings.TrimSpace(site.API) == "" {
		name := strings.TrimSpace(site.Name)
		if name == "" {
			name = strings.TrimSpace(site.Key)
		}
		if name == "" {
			name = "未选站"
		}
		return model.Result{Success: false}, fmt.Errorf("站点「%s」无接口地址，请换源或换站", name)
	}

	switch site.TypeID() {
	case 3: // Spider
		sp := s.cfg.Spider(site)
		skipHome := settings.ConsumeCrash()
		var home string
		if !skipHome {
			var herr error
			home, herr = sp.HomeContent(true)
			if herr != nil {
				return model.Result{Success: false}, herr
			}
		}
		result, err = decodeResult(home)
		if err != nil {
			return model.Result{Success: false}, err
		}
		if !skipHome {
			hv, herr := sp.HomeVideoContent()
			if herr != nil {
				return model.Result{Success: false}, herr
			}
			extra, _ := decodeResult(hv)
			if len(extra.List) > 0 {
				result.List = extra.List
			}
		}
		applyTypes(site, &result)
	case 4:
		if fetched, ferr := fetchExt(site); ferr == nil {
			after := strings.TrimSpace(fetched.Ext.String())
			before := strings.TrimSpace(site.Ext.String())
			if s.cfg != nil && after != "" && after != before {
				s.cfg.SetSiteExt(site.Key, fetched.Ext)
			}
			site = fetched
		}
		var body string
		body, err = siteCall(site, map[string]string{"filter": "true"})
		if err != nil {
			return model.Result{Success: false}, err
		}
		result, err = fromType(4, body)
		if err != nil {
			return model.Result{Success: false}, err
		}
		applyTypes(site, &result)
	case 0, 1, 2:
		// type2：非 spider 分支，JSON 解析（FromType≠0→JSON）。
		var body string
		body, err = util.HTTPGetParamsInsecure(site.API, map[string]string(site.Header), nil)
		if err != nil {
			return model.Result{Success: false}, err
		}
		result, err = fromType(site.TypeID(), body)
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
// 进目录用条目所属站，而不是强制首页。
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
		if native, ok := localDirCategory(tid); ok {
			result = native
		} else {
			sp := s.cfg.Spider(site)
			var raw string
			raw, err = sp.CategoryContent(tid, pg, true, extend)
			if err != nil {
				return model.Result{Success: false}, err
			}
			result, err = decodeResult(raw)
		}
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
		result, err = fromType(site.TypeID(), body)
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

func (s *SiteService) DetailContent(reqKey string, vod model.Vod) (model.Vod, error) {
	site := vod.Site
	if site == nil {
		h := s.cfg.Home()
		site = &h
	}

	// SiteApi.detailContent：site.isEmpty() && PUSH.equals(key) 时把 id 当播放地址。
	if site.IsEmpty() && reqKey == PushAgentKey {
		id := vod.VodID.String()
		detail := model.Vod{
			VodID:       model.FlexString(id),
			VodName:     id,
			VodPic:      PushAgentPic,
			VodPlayURL:  id,
			VodPlayFrom: "推送",
			Site:        &model.Site{Key: PushAgentKey, Name: "推送"},
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
		result, err = fromType(site.TypeID(), body)
	default:
		return vod, fmt.Errorf("不支持的站源类型: %d", site.TypeID())
	}
	if err != nil {
		return vod, err
	}
	if len(result.List) == 0 {
		empty := model.Vod{Site: site}
		empty.SetVodFlags()
		s.mu.Lock()
		s.DetailResult = result
		s.mu.Unlock()
		return empty, nil
	}
	detail := result.List[0]
	detail.Site = site
	detail.SetVodFlags()
	// 磁力展开（DHT 等元数据）可能数十秒，不在详情关键路径同步执行；
	// UI 进详情后异步 POST /api/v1/detail/expand → thunder.ParseVodContext，失败时仍保留原 magnet 链、起播再试。
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

func (s *SiteService) PlayerContent(reqKey string, site model.Site, flag, id string) (model.Result, error) {
	var result model.Result
	var err error

	// SiteApi.playerContent：先停掉专用源/磁力任务。
	source.Stop()
	thunder.Stop()

	// site.isEmpty() && push_agent：直接把 id 当 url，再走 Source.fetch。
	if site.IsEmpty() && reqKey == PushAgentKey {
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
			// 让 spider 自己按其输入形态拼接/解析。
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
			result, err = fromType(4, body)
			if err != nil {
				return model.Result{Success: false}, err
			}
			result.Key = site.Key
			applySourceFetch(&result)
		case 0, 1, 2:
			rawID := id
			// SiteApi：setUrl(id) 用原始剧集 id；parse 用 Sniffer.isVideoFormat(id)。
			parseVal := 1
			rules := parse.GetRules()
			if len(rules) == 0 && s.cfg != nil {
				rules = s.cfg.API().Rules
			}
			if parse.IsVideoFormatRules(rawID, rules) && strings.TrimSpace(site.PlayURL) == "" {
				parseVal = 0
			}
			result = model.Result{
				Success: true,
				URL:     model.URL{URLs: []string{rawID}},
				Flag:    flag,
				Key:     site.Key,
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
	result.Header = resultOrSiteHeader(site.Header, result.Header)
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

// applySourceFetch Source.fetch：特殊 scheme / .strm 预处理后再二次解析/起播。
// - video:// → 剥前缀 + parse=1（逼宿主嗅探）
// - push://  → 剥前缀 + parse=0（桌面直接播内层 URL）
// - *.strm  → 读文本首行真实地址 + parse=0
// 只处理 URL.Position 对应项并写回同 index（Url.v / replace）。
// Force / JianPian / TVBus / Youtube 依赖 Android Native 预处理。
func applySourceFetch(r *model.Result) {
	if r == nil || len(r.URL.URLs) == 0 {
		return
	}
	i := r.URL.Position
	if i < 0 {
		i = 0
	}
	if i >= len(r.URL.URLs) {
		i = len(r.URL.URLs) - 1
	}
	out, forceParse, directPlay := source.Prepare(r.URL.URLs[i])
	if forceParse || directPlay {
		r.URL.URLs[i] = out
	}
	switch {
	case forceParse:
		r.Parse = model.FlexInt{Valid: true, Value: 1}
	case directPlay:
		r.Parse = model.FlexInt{Valid: true, Value: 0}
	}
}

func applyThunderFetch(r *model.Result) error {
	if r == nil || len(r.URL.URLs) == 0 {
		return nil
	}
	i := r.URL.Position
	if i < 0 {
		i = 0
	}
	if i >= len(r.URL.URLs) {
		i = len(r.URL.URLs) - 1
	}
	u := r.URL.URLs[i]
	if u == "" || !thunder.Match(u) {
		return nil
	}
	local, err := thunder.Fetch(u)
	if err != nil {
		return err
	}
	r.URL.URLs[i] = local
	r.Parse = model.FlexInt{Valid: true, Value: 0}
	return nil
}

func (s *SiteService) Search(keyword string, siteKeys []string) ([]model.Collect, error) {
	return s.SearchParallel(keyword, siteKeys, 1)
}

// SearchParallel 多站并发搜索，maxConcurrent 为并发上限（<=0 时默认 4）。
func (s *SiteService) SearchParallel(keyword string, siteKeys []string, maxConcurrent int) ([]model.Collect, error) {
	keyword = strings.TrimSpace(keyword)
	if spider.TransEnabled() {
		keyword = spider.T2S(keyword)
	}
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
		sp := s.cfg.SpiderOnly(site)
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
		result, err := fromType(site.TypeID(), body)
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

func resultOrSiteHeader(siteHdr, resultHdr model.FlexHeader) model.FlexHeader {
	// Result.setHeader：结果已有头则保留，否则用站点头。
	if len(resultHdr) == 0 {
		return siteHdr
	}
	return resultHdr
}

// Action SiteApi.action：type3 爬虫；type4 把 action 当 URL GET；其它空。
func (s *SiteService) Action(site model.Site, action string) (string, error) {
	action = strings.TrimSpace(action)
	var raw string
	var err error
	switch site.TypeID() {
	case 3:
		raw, err = s.cfg.Spider(site).Action(action)
		if err != nil {
			return "", err
		}
	case 4:
		// OkHttp.string：非 http / 异常→""；Result.fromJson 空→{}；不向调用方抛错。
		if action == "" || !strings.HasPrefix(strings.ToLower(action), "http") {
			return "{}", nil
		}
		body, gerr := util.HTTPGetParamsInsecure(action, nil, nil)
		if gerr != nil || strings.TrimSpace(body) == "" {
			return "{}", nil
		}
		raw = body
	default:
		return "{}", nil
	}
	// SiteApi.action → Result.fromJson（会 trans）。
	result, ferr := fromType(1, raw)
	if ferr != nil {
		if strings.TrimSpace(raw) == "" {
			return "{}", nil
		}
		return raw, nil
	}
	out := util.EncodeJSON(result)
	if strings.TrimSpace(out) == "" {
		return "{}", nil
	}
	return out, nil
}

// ManualVideoCheck CustomWebView：spider.manualVideoCheck()。
func (s *SiteService) ManualVideoCheck(site model.Site) bool {
	sp := s.cfg.Spider(site)
	ok, err := sp.ManualVideoCheck()
	return err == nil && ok
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
	return fromType(1, raw)
}

func fromType(typeID int, raw string) (model.Result, error) {
	result, err := model.FromType(typeID, raw)
	if err != nil {
		return result, err
	}
	spider.S2TResult(&result)
	return result, nil
}
