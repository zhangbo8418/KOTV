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
	"github.com/bobo/KOTV/internal/source"
	"github.com/bobo/KOTV/internal/spider"
	"github.com/bobo/KOTV/internal/thunder"
	"github.com/bobo/KOTV/internal/util"
	"golang.org/x/sync/singleflight"
)

// PushAgentKey 无站点配置时的推送入口 key。
const PushAgentKey = "push_agent"

// PushAgentPic 推送详情占位图（TV R.string.push_image 等价 data URI，1x1 JPEG）。
const PushAgentPic = "data:image/jpeg;base64,/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAgGBgcGBQgHBwcJCQgKDBQNDAsLDBkSEw8UHRofHh0aHBwgJC4nICIsIxwcKDcpLDAxNDQ0Hyc5PTgyPC4zNDL/2wBDAQkJCQwLDBgNDRgyIRwhMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjIyMjL/wAARCAABAAEDASIAAhEBAxEB/8QAFQABAQAAAAAAAAAAAAAAAAAAAAn/xAAUEAEAAAAAAAAAAAAAAAAAAAAA/8QAFQEBAQAAAAAAAAAAAAAAAAAAAAX/xAAUEQEAAAAAAAAAAAAAAAAAAAAA/9oADAMBAAIQAxAAAAGfAP/EABQQAQAAAAAAAAAAAAAAAAAAAAD/2gAIAQEAAQUCf//EABQRAQAAAAAAAAAAAAAAAAAAAAD/2gAIAQMBAT8Bf//EABQRAQAAAAAAAAAAAAAAAAAAAAD/2gAIAQIBAT8Bf//Z"

// SiteService 站点内容服务。
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

// DropContentCache 清内容缓存，不停止 JVM/Py/JS。
func (s *SiteService) DropContentCache() {
	s.loadEpoch.Add(1)
	s.mu.Lock()
	s.invalidateContentCache()
	s.mu.Unlock()
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
	// 与写入条件一致：仅 Types>0 才命中，避免「有 list 无 class」假命中却永不写入。
	if s.homeCacheSite == site.Key && len(s.HomeResult.Types) > 0 {
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
	// 没有分类的结果不写入缓存。列表有片但 class 为空时，下一次仍重新请求。
	if len(result.Types) > 0 {
		s.HomeResult = result
		s.homeCacheSite = site.Key
	}
	s.mu.Unlock()
	return result, nil
}

func (s *SiteService) homeContentFor(site model.Site) (model.Result, error) {
	var result model.Result
	var err error

	switch site.TypeID() {
	case 3: // Spider：api 为 csp_/脚本路径，靠 jar+key 加载，勿按 HTTP 空址早拒。
		if !spider.RunnableAPI(site.API) {
			return model.Result{Success: false}, fmt.Errorf("站点「%s」没有可用爬虫", siteLabel(site))
		}
		sp := s.cfg.Spider(site)
		type homeBundler interface {
			HomeBundle(filter bool) (home string, homeVod string, err error)
		}
		var home, hv string
		var herr error
		if hb, ok := sp.(homeBundler); ok {
			home, hv, herr = hb.HomeBundle(true)
		} else {
			home, herr = sp.HomeContent(true)
			if herr == nil {
				hv, herr = sp.HomeVideoContent()
			}
		}
		if herr != nil {
			return model.Result{Success: false}, herr
		}
		result, err = decodeResult(home)
		if err != nil {
			return model.Result{Success: false}, err
		}
		extra, _ := decodeResult(hv)
		if len(extra.List) > 0 {
			result.List = extra.List
		}
		applyTypes(site, &result)
	case 4:
		if strings.TrimSpace(site.API) == "" {
			return model.Result{Success: false}, fmt.Errorf("站点「%s」无接口地址，请换源或换站", siteLabel(site))
		}
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
		if strings.TrimSpace(site.API) == "" {
			return model.Result{Success: false}, fmt.Errorf("站点「%s」无接口地址，请换源或换站", siteLabel(site))
		}
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

func siteLabel(site model.Site) string {
	name := strings.TrimSpace(site.Name)
	if name == "" {
		name = strings.TrimSpace(site.Key)
	}
	if name == "" {
		name = "未选站"
	}
	return name
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
	// 空列表不入缓存：中断/瞬时失败会写出空页，再进同类目会一直「暂无内容」。
	if len(result.List) > 0 {
		s.mu.Lock()
		s.putCategoryCache(site, tid, pg, extend, result)
		s.mu.Unlock()
	}
	return result, nil
}

func (s *SiteService) DetailContent(reqKey string, vod model.Vod) (model.Vod, error) {
	site := vod.Site
	if site == nil {
		h := s.cfg.Home()
		site = &h
	}

	// 空站点且为推送入口：把 id 当播放地址。
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
	// 磁力 / 播放列表展开可能数十秒，不在详情关键路径同步执行；
	// UI 进详情后异步 POST /api/v1/detail/expand，失败时仍保留原链、起播再试。
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

// ReplaceDetailCache 用展开后的剧集覆盖详情缓存，供 EpisodeURLByIndex / 起播按集下标取址。
func (s *SiteService) ReplaceDetailCache(vod model.Vod) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if len(s.DetailResult.List) == 0 {
		s.DetailResult = model.Result{Success: true, List: []model.Vod{vod}}
		return
	}
	s.DetailResult.List[0] = vod
}

// EpisodeURLByIndex 从详情缓存按线路+集下标取原始剧集地址（DTO 可能已置空直开字段）。
func (s *SiteService) EpisodeURLByIndex(vodID, flag string, index int) (string, bool) {
	if index < 0 {
		return "", false
	}
	v, ok := s.CachedDetail(vodID)
	if !ok {
		return "", false
	}
	v.SetVodFlags()
	flag = strings.TrimSpace(flag)
	for _, f := range v.VodFlags {
		if flag != "" && f.Flag != flag && f.Show != flag {
			continue
		}
		if index >= len(f.Episodes) {
			return "", false
		}
		u := strings.TrimSpace(f.Episodes[index].URL)
		return u, u != ""
	}
	return "", false
}

func (s *SiteService) PlayerContent(reqKey string, site model.Site, flag, id string) (model.Result, error) {
	var result model.Result
	var err error

	// 起播前先停掉专用源/磁力任务。
	source.Stop()
	thunder.Stop()

	// site.isEmpty() && push_agent：直接把 id 当 url，再走专用源预处理。
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
			// CMS：url 用原始剧集 id；已是直链且站点无 playUrl 时 parse=0。
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

	// 仅当结果头为空时写入站点头。
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

// applySourceFetch 起播前预处理当前清晰度 URL，并写回 parse：
// - video:// → 剥前缀 + parse=1（宿主嗅探）
// - push:// / *.strm → 展开内层地址 + parse=0
// - 荐片 / TVBus / Force / YouTube 等 Match → 仅 parse=0（真正 Fetch 在 APIPlay）
// 只处理 URL.Position 对应项。
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
	case source.Match(r.URL.URLs[i]):
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

// SearchFirstExact 只在可搜索、可换源、允许快速搜索的站里找片名完全相等的第一条。
// 命中后立刻返回，不等其余站。不写入 SearchResult。
func (s *SiteService) SearchFirstExact(keyword string, siteKeys []string, exclude []model.VodKey) (model.Vod, bool, error) {
	matchName := strings.TrimSpace(keyword)
	if matchName == "" {
		return model.Vod{}, false, nil
	}
	query := matchName
	if spider.TransEnabled() {
		query = spider.T2S(matchName)
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
	parentCID := hostclient.Current()
	parentUID := hostclient.CurrentUserID()
	parentDed := hostclient.DedicatedRuntime()
	vod, ok := searchFirstExact(sites, matchName, query, vodKeySet(exclude), func(site model.Site, kw string) ([]model.Vod, error) {
		done := hostclient.EnterSession(parentCID, parentUID, parentDed)
		defer done()
		return s.searchSite(site, kw, true, "1")
	})
	return vod, ok, nil
}

func vodKeySet(exclude []model.VodKey) map[string]struct{} {
	out := make(map[string]struct{}, len(exclude))
	for _, k := range exclude {
		site := strings.TrimSpace(k.Site)
		id := strings.TrimSpace(k.ID)
		if site == "" || id == "" {
			continue
		}
		out[site+"\n"+id] = struct{}{}
	}
	return out
}

// searchFirstExact 某个站返回与原名完全相等的第一条后立刻交出结果。query 只发给站点。
func searchFirstExact(sites []model.Site, matchName, query string, exclude map[string]struct{}, search func(model.Site, string) ([]model.Vod, error)) (model.Vod, bool) {
	matchName = strings.TrimSpace(matchName)
	query = strings.TrimSpace(query)
	if matchName == "" || query == "" || search == nil {
		return model.Vod{}, false
	}
	eligible := make([]model.Site, 0, len(sites))
	for _, site := range sites {
		if strings.TrimSpace(site.Key) == "" || !site.IsSearchable() || !site.IsChangeable() || !site.IsQuickSearch() {
			continue
		}
		eligible = append(eligible, site)
	}
	if len(eligible) == 0 {
		return model.Vod{}, false
	}
	const maxConcurrent = 4
	sem := make(chan struct{}, maxConcurrent)
	found := make(chan model.Vod, 1)
	var once sync.Once
	var wg sync.WaitGroup
	for _, site := range eligible {
		wg.Add(1)
		go func(site model.Site) {
			defer wg.Done()
			sem <- struct{}{}
			defer func() { <-sem }()
			list, err := search(site, query)
			if err != nil || len(list) == 0 {
				return
			}
			for _, v := range list {
				name := strings.TrimSpace(v.VodName)
				id := strings.TrimSpace(v.VodID.String())
				if name != matchName || id == "" {
					continue
				}
				if _, skip := exclude[site.Key+"\n"+id]; skip {
					continue
				}
				siteCopy := site
				v.Site = &siteCopy
				once.Do(func() { found <- v })
				return
			}
		}(site)
	}
	done := make(chan struct{})
	go func() {
		wg.Wait()
		close(done)
	}()
	select {
	case v := <-found:
		return v, true
	case <-done:
		select {
		case v := <-found:
			return v, true
		default:
			return model.Vod{}, false
		}
	}
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
	// 结果已有头则保留，否则用站点头。
	if len(resultHdr) == 0 {
		return siteHdr
	}
	return resultHdr
}

// Action type3 走爬虫 action；type4 把 action 当 URL GET；其它返回空 JSON。
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

// ManualVideoCheck 是否由爬虫接管视频格式判定。
func (s *SiteService) ManualVideoCheck(site model.Site) bool {
	sp := s.cfg.Spider(site)
	ok, err := sp.ManualVideoCheck()
	return err == nil && ok
}

// IsVideoFormat 判断是否为直链视频：爬虫 manualVideoCheck 为真时用爬虫 isVideo，
// 否则用默认嗅探规则（含配置 rules.regex/exclude）。
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
