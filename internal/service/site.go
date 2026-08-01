package service

import (
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"sync"
	"sync/atomic"

	"github.com/bobo/KOTV/internal/config"
	"github.com/bobo/KOTV/internal/model"
	"github.com/bobo/KOTV/internal/parse"
	"github.com/bobo/KOTV/internal/spider"
	"github.com/bobo/KOTV/internal/thunder"
	"github.com/bobo/KOTV/internal/util"
	"golang.org/x/sync/singleflight"
)

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

// InvalidateLoads 作废进行中的首页加载，并打断卡住的 JAR bridge。
func (s *SiteService) InvalidateLoads() {
	s.loadEpoch.Add(1)
	s.mu.Lock()
	s.invalidateContentCache()
	s.mu.Unlock()
	// 先软中断脚本，再杀 JVM，最后 Destroy，降低 QuickJS/CGO 与 Kill 竞态。
	spider.InterruptScriptSpiders()
	spider.InterruptJavaBridge()
	spider.ResetScriptSpiders()
	spider.ClearJarBridgeOnSwitch()
}

// HomeLoadEpoch 返回当前加载世代，供 UI 丢弃过期结果。
func (s *SiteService) HomeLoadEpoch() uint64 {
	return s.loadEpoch.Load()
}

// CancelPendingContent 打断进行中的 spider 请求（分类切换等），不影响首页 loadEpoch。
func (s *SiteService) CancelPendingContent() {
	spider.InterruptJavaBridge()
	spider.InterruptScriptSpiders()
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
	case 0, 1:
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
	site := s.cfg.Home()
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
	case 0, 1, 4:
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
	case 0, 1, 4:
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

	id = normalizePlayID(site, id)

	switch site.TypeID() {
	case 3:
		sp := s.cfg.Spider(site)
		vipFlags := s.cfg.API().Flags
		var raw string
		raw, err = sp.PlayerContent(flag, id, vipFlags)
		if err != nil {
			return model.Result{Success: false}, err
		}
		result, err = decodeResult(raw)
		if err != nil {
			return model.Result{Success: false}, err
		}
		result.Key = site.Key
		sanitizeResultPlayURLs(site, &result)
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
		sanitizeResultPlayURLs(site, &result)
	case 0, 1:
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
	default:
		return model.Result{Success: false}, fmt.Errorf("不支持的站源类型: %d", site.TypeID())
	}

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
	id = model.CleanEpisodePlayURL(id)
	if id == "" || strings.HasPrefix(id, "http://") || strings.HasPrefix(id, "https://") ||
		thunder.Match(id) || strings.HasPrefix(strings.ToLower(id), "ed2k:") {
		return id
	}
	bases := make([]string, 0, 3)
	switch site.TypeID() {
	case 0, 1:
		bases = append(bases, site.API)
	}
	if site.Header != nil {
		for _, k := range []string{"Referer", "referer"} {
			if r := strings.TrimSpace(site.Header[k]); strings.HasPrefix(r, "http") {
				bases = append(bases, r)
			}
		}
	}
	for _, base := range bases {
		if abs := util.ResolveRelativeURL(base, id); abs != "" && abs != id {
			return abs
		}
	}
	return id
}

func sanitizeResultPlayURLs(site model.Site, r *model.Result) {
	if r == nil || len(r.URL.URLs) == 0 {
		return
	}
	for i, u := range r.URL.URLs {
		r.URL.URLs[i] = normalizePlayID(site, u)
	}
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
	for i, site := range searchable {
		wg.Add(1)
		go func(i int, site model.Site) {
			defer wg.Done()
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
	case 0, 1, 4:
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
	if len(siteHdr) == 0 {
		return resultHdr
	}
	if len(resultHdr) == 0 {
		return siteHdr
	}
	merged := make(model.FlexHeader, len(siteHdr)+len(resultHdr))
	for k, v := range siteHdr {
		merged[k] = v
	}
	for k, v := range resultHdr {
		merged[k] = v
	}
	return merged
}

// Action 对齐 TV SiteApi.action：type3 爬虫；type4 把 action 当 URL GET；其它空。
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

// IsVideoFormat 对齐 TV CustomWebView：manualVideoCheck 为真时走爬虫 isVideo。
func (s *SiteService) IsVideoFormat(site model.Site, u string) bool {
	sp := s.cfg.Spider(site)
	if ok, err := sp.ManualVideoCheck(); err == nil && ok {
		if v, err := sp.IsVideoFormat(u); err == nil {
			return v
		}
	}
	return parse.IsVideoFormat(u)
}

func decodeResult(raw string) (model.Result, error) {
	return model.FromType(1, raw)
}
