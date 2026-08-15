package config

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"log"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync"

	"github.com/bobo/KOTV/internal/database"
	"github.com/bobo/KOTV/internal/localproxy"
	"github.com/bobo/KOTV/internal/model"
	"github.com/bobo/KOTV/internal/parse"
	"github.com/bobo/KOTV/internal/settings"
	"github.com/bobo/KOTV/internal/spider"
	"github.com/bobo/KOTV/internal/util"
)

// Manager 管理点播配置，点播配置管理。
type Manager struct {
	mu        sync.RWMutex
	api       model.Api
	home      model.Site
	db        *database.DB
	ephemeral bool // 多用户临时会话：不写 settings.VOD / 不持久化 home
}

var defaultMgr *Manager

func Default() *Manager {
	return defaultMgr
}

func NewManager(db *database.DB) *Manager {
	defaultMgr = &Manager{db: db, home: model.Site{Key: "", Name: ""}}
	return defaultMgr
}

func (m *Manager) API() model.Api {
	m.mu.RLock()
	defer m.mu.RUnlock()
	return m.api
}

func (m *Manager) Home() model.Site {
	m.mu.RLock()
	defer m.mu.RUnlock()
	return m.home
}

// SetHome 切换首页站点；非 ephemeral 时持久化到 DB。
func (m *Manager) SetHome(site model.Site) {
	m.mu.Lock()
	m.home = site
	cfgURL := m.api.URL
	ephemeral := m.ephemeral
	m.mu.Unlock()
	if ephemeral {
		return
	}
	if m.db != nil && site.Key != "" && cfgURL != "" {
		if err := m.db.SetConfigHome(cfgURL, database.ConfigTypeSite, site.Key); err != nil {
			log.Printf("保存首页站点失败: %v", err)
		}
	}
}

// Ephemeral 是否为多用户临时会话（不写共享 settings / home）。
func (m *Manager) Ephemeral() bool {
	return m.ephemeral
}

// CloneEphemeral 深拷贝站点相关切片，供按 Scope 隔离的「当前选中源」会话。
// 列表内容从共享配置克隆起步；之后该会话换源不写全局 settings.VOD。
func (m *Manager) CloneEphemeral() *Manager {
	m.mu.RLock()
	defer m.mu.RUnlock()
	api := m.api
	api.Sites = append([]model.Site(nil), m.api.Sites...)
	api.Lives = append([]model.Live(nil), m.api.Lives...)
	api.Parses = append([]model.Parse(nil), m.api.Parses...)
	api.Rules = append([]model.Rule(nil), m.api.Rules...)
	api.Flags = append([]string(nil), m.api.Flags...)
	api.Ads = append([]string(nil), m.api.Ads...)
	if m.api.Headers != nil {
		api.Headers = append(json.RawMessage(nil), m.api.Headers...)
	}
	if m.api.Proxy != nil {
		api.Proxy = append(json.RawMessage(nil), m.api.Proxy...)
	}
	if m.api.Hosts != nil {
		api.Hosts = append(json.RawMessage(nil), m.api.Hosts...)
	}
	if m.api.Doh != nil {
		api.Doh = append(json.RawMessage(nil), m.api.Doh...)
	}
	return &Manager{
		api:       api,
		home:      m.home,
		db:        m.db,
		ephemeral: true,
	}
}

func (m *Manager) Sites() []model.Site {
	m.mu.RLock()
	defer m.mu.RUnlock()
	out := make([]model.Site, 0, len(m.api.Sites))
	for _, s := range m.api.Sites {
		if !s.IsHide() {
			out = append(out, s)
		}
	}
	return out
}

func (m *Manager) GetSite(key string) *model.Site {
	m.mu.RLock()
	defer m.mu.RUnlock()
	for i := range m.api.Sites {
		if m.api.Sites[i].Key == key {
			s := m.api.Sites[i]
			return &s
		}
	}
	return nil
}

// GetLive LiveConfig.getLive：按直播源 name 查找（proxy siteKey 用）。
func (m *Manager) GetLive(name string) *model.Live {
	m.mu.RLock()
	defer m.mu.RUnlock()
	name = strings.TrimSpace(name)
	if name == "" {
		return nil
	}
	for i := range m.api.Lives {
		if m.api.Lives[i].Name == name {
			l := m.api.Lives[i]
			return &l
		}
	}
	return nil
}

// ToggleSiteSearchable 切换可搜索。
func (m *Manager) ToggleSiteSearchable(key string) (*model.Site, error) {
	return m.toggleSiteFlag(key, true)
}

// ToggleSiteChangeable 切换可换源。
func (m *Manager) ToggleSiteChangeable(key string) (*model.Site, error) {
	return m.toggleSiteFlag(key, false)
}

// SetAllSitesSearchable 全部可搜索。
func (m *Manager) SetAllSitesSearchable(on bool) error {
	return m.setAllSiteFlags(true, on)
}

// SetAllSitesChangeable 全部可换源。
func (m *Manager) SetAllSitesChangeable(on bool) error {
	return m.setAllSiteFlags(false, on)
}

func (m *Manager) toggleSiteFlag(key string, searchable bool) (*model.Site, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	for i := range m.api.Sites {
		if m.api.Sites[i].Key != key {
			continue
		}
		site := &m.api.Sites[i]
		ok := false
		if searchable {
			ok = site.SetSearchable(!site.IsSearchable())
		} else {
			ok = site.SetChangeable(!site.IsChangeable())
		}
		if !ok {
			s := *site
			return &s, nil
		}
		if err := m.persistSiteFlagsLocked(*site); err != nil {
			return nil, err
		}
		if m.home.Key == site.Key {
			m.home = *site
		}
		s := *site
		return &s, nil
	}
	return nil, fmt.Errorf("site not found: %s", key)
}

func (m *Manager) setAllSiteFlags(searchable bool, on bool) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	for i := range m.api.Sites {
		site := &m.api.Sites[i]
		if searchable {
			_ = site.SetSearchable(on)
		} else {
			_ = site.SetChangeable(on)
		}
		if err := m.persistSiteFlagsLocked(*site); err != nil {
			return err
		}
		if m.home.Key == site.Key {
			m.home = *site
		}
	}
	return nil
}

func (m *Manager) persistSiteFlagsLocked(site model.Site) error {
	if m.ephemeral || m.db == nil {
		return nil
	}
	if site.ID > 0 {
		return m.db.UpdateSiteFlags(site.ID, site.Searchable, site.Changeable)
	}
	cfg, err := m.db.FindConfig(m.api.URL, database.ConfigTypeSite)
	if err != nil {
		return err
	}
	if cfg == nil || cfg.ID == 0 {
		return fmt.Errorf("config not found")
	}
	return m.db.UpdateSiteFlagsByKey(cfg.ID, site.Key, site.Searchable, site.Changeable)
}

func (m *Manager) Clear() {
	m.mu.Lock()
	m.api = model.Api{}
	m.home = model.Site{Key: "", Name: ""}
	ephemeral := m.ephemeral
	m.mu.Unlock()
	// ephemeral 换源不得清空全局爬虫池，否则会误伤其他 client。
	if !ephemeral {
		spider.Clear()
	}
}

// EnsureVodFromHistory 对齐 TV Config.vod()：开 HTTP 前用 DB 最新源同步 settings.VOD。
func (m *Manager) EnsureVodFromHistory() {
	if u := m.syncVodPointerFromDB(); u != "" {
		log.Printf("boot: 当前点播源指针 <- DB: %s", u)
	}
}

// InitFromSettings 对齐 TV VodConfig.init().load()：当前源 = config 表 time DESC 最新一条。
func (m *Manager) InitFromSettings() error {
	if c := m.latestSiteConfig(); c != nil {
		_ = m.syncVodPointerFromDB()
		if strings.TrimSpace(c.JSON) != "" {
			return m.ParseConfig(c, true)
		}
		if strings.TrimSpace(c.URL) != "" {
			return m.ParseConfig(c, false)
		}
	}
	return m.initFromVod(settings.Get(settings.VOD))
}

func (m *Manager) latestSiteConfig() *database.Config {
	if m == nil || m.db == nil {
		return nil
	}
	c, err := m.db.FindConfigByType(int64(database.ConfigTypeSite))
	if err != nil || c == nil {
		return nil
	}
	if strings.TrimSpace(c.URL) == "" && strings.TrimSpace(c.JSON) == "" {
		return nil
	}
	return c
}

func (m *Manager) syncVodPointerFromDB() string {
	c := m.latestSiteConfig()
	if c == nil {
		return ""
	}
	u := strings.TrimSpace(c.URL)
	if u == "" {
		return ""
	}
	if settings.Get(settings.VOD) != u {
		settings.Set(settings.VOD, u)
		_ = settings.Save()
	}
	return u
}

func (m *Manager) initFromVod(vod string) error {
	vod = NormalizeSource(vod)
	if vod == "" {
		return fmt.Errorf("未配置点播源")
	}
	// 内联键 (inline://<hash>) 与 URL 一样作为唯一键；切换时按该键回查已落盘的 JSON 正文。
	if isInlineConfigKey(vod) {
		cfg, err := m.db.FindConfig(vod, database.ConfigTypeSite)
		if err != nil {
			return err
		}
		if cfg == nil {
			return fmt.Errorf("配置不存在: %s", vod)
		}
		return m.ParseConfig(cfg, cfg.JSON != "")
	}
	// http(s)/file URL 按远程或本地配置拉取
	if looksLikeURL(vod) {
		cfg, err := m.db.FindConfig(vod, database.ConfigTypeSite)
		if err != nil {
			return err
		}
		if cfg == nil {
			cfg = &database.Config{Type: database.ConfigTypeSite, URL: vod}
		} else {
			cfg.URL = vod
		}
		return m.ParseConfig(cfg, false)
	}
	// 直接粘贴的 JSON 正文：无 url，按内容派生稳定键（同份幂等、不同份并存）。
	if strings.HasPrefix(vod, "{") || strings.HasPrefix(vod, "[") {
		cfg := &database.Config{Type: database.ConfigTypeSite, URL: inlineConfigKey(vod), JSON: vod, Name: inlineConfigName(vod)}
		return m.ParseConfig(cfg, true)
	}
	cfg := &database.Config{Type: database.ConfigTypeSite, URL: vod}
	return m.ParseConfig(cfg, false)
}

// resolveConfig 把用户输入（裸 URL / 裸 JSON / 已存的内联键）解析为要持久化的 Config 行。
// 每个源以 (url, type) 唯一键存一行；裸 JSON 没有 url，用内容哈希键代替，避免不同 JSON 互相覆盖。
func (m *Manager) resolveConfig(source string) (*database.Config, error) {
	if isInlineConfigKey(source) {
		cfg, err := m.db.FindConfig(source, database.ConfigTypeSite)
		if err != nil {
			return nil, err
		}
		if cfg == nil {
			return nil, fmt.Errorf("配置不存在: %s", source)
		}
		return cfg, nil
	}
	if strings.HasPrefix(source, "{") || strings.HasPrefix(source, "[") {
		return &database.Config{
			Type: database.ConfigTypeSite,
			URL:  inlineConfigKey(source),
			JSON: source,
			Name: inlineConfigName(source),
		}, nil
	}
	return &database.Config{Type: database.ConfigTypeSite, URL: source}, nil
}

// SourceDisplayName 无接口名时回落为完整地址（勿截成路径末段）。
func SourceDisplayName(raw string) string {
	return strings.TrimSpace(raw)
}

// ConfigLabel 有接口名显示名字，没有则显示完整接口地址。
func ConfigLabel(name, rawURL string) string {
	name = strings.TrimSpace(name)
	rawURL = strings.TrimSpace(rawURL)
	if name == "" {
		return rawURL
	}
	return name
}

// inlineConfigKey 把无 url 的内联 JSON 映射成稳定 key，使不同正文各占一行。
func inlineConfigKey(vod string) string {
	sum := sha256.Sum256([]byte(vod))
	return "inline://" + hex.EncodeToString(sum[:])[:16]
}

func isInlineConfigKey(s string) bool {
	return strings.HasPrefix(s, "inline://")
}

// inlineConfigName 取 JSON 顶层 name/title/key 作显示名；缺省回退到哈希后缀以便区分。
func inlineConfigName(vod string) string {
	var head struct {
		Key   string `json:"key"`
		Name  string `json:"name"`
		Title string `json:"title"`
	}
	if err := json.Unmarshal([]byte(vod), &head); err == nil {
		for _, v := range []string{head.Name, head.Title, head.Key} {
			if strings.TrimSpace(v) != "" {
				return strings.TrimSpace(v)
			}
		}
	}
	return "内联配置 " + inlineConfigKey(vod)[len("inline://"):]
}

func looksLikeURL(s string) bool {
	s = strings.ToLower(strings.TrimSpace(s))
	return strings.HasPrefix(s, "http://") || strings.HasPrefix(s, "https://") || strings.HasPrefix(s, "file://")
}

// NormalizeSource 本地配置路径统一成 file://，便于拉取配置并解析相对 spider.jar。
func NormalizeSource(source string) string {
	source = strings.TrimSpace(source)
	if source == "" || looksLikeURL(source) || strings.HasPrefix(source, "{") || strings.HasPrefix(source, "[") {
		return source
	}
	p := source
	if strings.HasPrefix(p, "~/") {
		if home, err := os.UserHomeDir(); err == nil {
			p = filepath.Join(home, p[2:])
		}
	}
	if abs, err := filepath.Abs(p); err == nil {
		p = abs
	}
	if st, err := os.Stat(p); err == nil && !st.IsDir() {
		u := url.URL{Scheme: "file", Path: filepath.ToSlash(p)}
		return u.String()
	}
	return source
}

// LoadFromSource 加载 URL 或 JSON 正文；非 ephemeral 时写回 settings.VOD。
func (m *Manager) LoadFromSource(source string) error {
	source = NormalizeSource(source)
	if source == "" {
		return fmt.Errorf("请输入点播源 URL 或粘贴 JSON")
	}
	// 每个源以 (url, type) 唯一键写入共享库，本机与远端会话共用同一份源列表。
	// ephemeral 只表示该 Scope 不写全局 settings.VOD 指针、不杀共享爬虫，仍必须把源行写入共享库；
	// 否则会话模式下 APIListRepos 读到的永远是空表，换源不落盘。
	if m.db != nil || !m.ephemeral {
		cfg, err := m.resolveConfig(source)
		if err != nil {
			return err
		}
		if m.db != nil {
			if _, err := m.db.UpsertConfig(cfg); err != nil {
				return err
			}
		}
		if !m.ephemeral {
			settings.Set(settings.VOD, cfg.URL)
			_ = settings.Save()
		}
	}
	return m.initFromVod(source)
}

// ParseConfig 解析配置。
func (m *Manager) ParseConfig(cfg *database.Config, isJSON bool) error {
	source := cfg.URL
	if isJSON {
		source = cfg.JSON
	}
	if !isJSON && strings.TrimSpace(source) == "" {
		return fmt.Errorf("点播源地址无效")
	}

	data, err := m.fetchData(source, isJSON, cfg.JSON)
	if err != nil {
		return err
	}
	if strings.TrimSpace(data) == "" {
		return fmt.Errorf("配置数据为空")
	}

	cleaned := util.CleanJSONComments(data)
	if depots := parseDepotIndex(cleaned); len(depots) > 0 {
		return m.loadDepotIndex(cfg, depots)
	}

	api, err := util.DecodeJSON[model.Api](cleaned)
	if err != nil {
		return fmt.Errorf("配置解析失败: %w", err)
	}
	// 空 sites 也照常加载（首页退化为空站点），不把整条源判失败。
	if len(api.Sites) == 0 {
		log.Printf("vod source %s has no sites, loading as empty", cfg.URL)
	}

	api.URL = cfg.URL
	api.Data = data
	api.Ref++
	m.expandLives(&api)

	// 后续相对 spider.jar / 站点 jar 都相对此基址解析。
	spider.SetConfigBase(cfg.URL)

	// headers/proxy/hosts/doh 按当前 hostclient 下发；ephemeral 也写（按 clientId 隔离，不覆盖他人）。
	spider.SetNetConfig(api.Headers, api.Proxy, api.Hosts, api.Doh)
	if !m.ephemeral {
		parse.SetVodAds(api.Ads)
		parse.SetVodRules(api.Rules)
	}

	if api.Spider != "" {
		if err := spider.LoadJar(api.Spider, cfg.URL); err != nil {
			log.Printf("spider.jar 加载失败: %v", err)
		}
	}

	resolveSitePaths(&api)
	resolveParsePaths(&api)
	resolveApiAssets(&api)
	// VodConfig.setParses：非空时在首位插入超级解析（type=4）。
	injectGodParse(&api)

	visible := filterVisible(api.Sites)
	home := resolveHome(cfg.Home, visible)
	if home.Key == "" || isMetaSite(home) {
		home = pickDefaultHome(visible)
	}
	if home.Key != "" {
		cfg.Home = home.Key
	}

	m.initLiveFromVod(cfg, &api)

	// 源行与站点始终写入共享库（含会话模式）；ephemeral 只隔离「当前选中源」的内存态，不阻碍持久化。
	if m.db != nil {
		cfgID, err := m.db.UpsertConfig(cfg)
		if err != nil {
			return err
		}
		_ = m.db.SyncSites(cfgID, api.Sites)
	}

	m.mu.Lock()
	m.api = api
	m.home = home
	m.mu.Unlock()

	return nil
}

// parseDepotIndex 识别多仓索引：{"urls":[{"name":"...","url":"..."}]}。
func parseDepotIndex(raw string) []model.Depot {
	type root struct {
		Msg  string            `json:"msg"`
		URLs []json.RawMessage `json:"urls"`
	}
	idx, err := util.DecodeJSON[root](raw)
	if err != nil || len(idx.URLs) == 0 {
		return nil
	}
	var out []model.Depot
	for _, item := range idx.URLs {
		var d model.Depot
		if err := json.Unmarshal(item, &d); err == nil && strings.TrimSpace(d.URL) != "" {
			out = append(out, d)
			continue
		}
		var plain string
		if err := json.Unmarshal(item, &plain); err == nil && strings.TrimSpace(plain) != "" {
			out = append(out, model.Depot{URL: plain})
		}
	}
	return out
}

// 批量写入 name+url → 删除索引自身 → 自动加载第一项真实配置。
func (m *Manager) loadDepotIndex(index *database.Config, depots []model.Depot) error {
	if len(depots) == 0 {
		return fmt.Errorf("仓库索引 urls 为空")
	}
	depotURLs := make(map[string]struct{}, len(depots))
	for _, d := range depots {
		url := strings.TrimSpace(d.URL)
		if url == "" {
			continue
		}
		depotURLs[url] = struct{}{}
		cfg := &database.Config{
			Type: database.ConfigTypeSite,
			URL:  url,
			Name: strings.TrimSpace(d.Name),
		}
		if _, err := m.db.UpsertConfig(cfg); err != nil {
			return fmt.Errorf("写入线路 %s 失败: %w", d.DisplayName(), err)
		}
		log.Printf("仓库索引已入库: %s → %s", d.DisplayName(), url)
	}
	if len(depotURLs) == 0 {
		return fmt.Errorf("仓库索引 urls 为空")
	}

	indexURL := strings.TrimSpace(index.URL)
	if indexURL != "" {
		if _, keep := depotURLs[indexURL]; !keep {
			_ = m.db.DeleteConfigByURL(indexURL, database.ConfigTypeSite)
		}
	}

	first := strings.TrimSpace(depots[0].URL)
	if !m.ephemeral {
		settings.Set(settings.VOD, first)
		_ = settings.Save()
	}

	next, err := m.db.FindConfig(first, database.ConfigTypeSite)
	if err != nil {
		return err
	}
	if next == nil {
		next = &database.Config{Type: database.ConfigTypeSite, URL: first, Name: strings.TrimSpace(depots[0].Name)}
	}
	log.Printf("仓库索引展开完成，加载首个线路: %s", first)
	return m.ParseConfig(next, false)
}

func (m *Manager) fetchData(source string, isJSON bool, inline string) (string, error) {
	if isJSON {
		return inline, nil
	}
	source = NormalizeSource(source)
	if strings.HasPrefix(source, "file://") {
		parsed, err := url.Parse(source)
		if err != nil {
			return "", err
		}
		name, err := url.PathUnescape(parsed.Path)
		if err != nil {
			return "", err
		}
		b, err := os.ReadFile(filepath.FromSlash(name))
		if err != nil {
			return "", err
		}
		return string(b), nil
	}
	return util.HTTPGet(source, nil)
}

func resolveHome(homeKey string, sites []model.Site) model.Site {
	if homeKey != "" {
		for _, s := range sites {
			if s.Key == homeKey {
				return s
			}
		}
	}
	return model.Site{}
}

func pickDefaultHome(sites []model.Site) model.Site {
	for _, s := range sites {
		if isMetaSite(s) {
			continue
		}
		return s
	}
	if len(sites) > 0 {
		return sites[0]
	}
	return model.Site{}
}

func isMetaSite(s model.Site) bool {
	n := strings.ToLower(s.Name + " " + s.Key + " " + s.API)
	for _, bad := range []string{
		"intruduce", "introduce", "登录", "配置", "网盘登录", "说明", "公告", "push",
		// 豆瓣首页多为 msearch: id，本站 detail 常为空，不宜作为默认首页。
		"douban", "豆瓣",
	} {
		if strings.Contains(n, bad) {
			return true
		}
	}
	return false
}

func filterVisible(sites []model.Site) []model.Site {
	out := make([]model.Site, 0, len(sites))
	for _, s := range sites {
		if !s.IsHide() {
			out = append(out, s)
		}
	}
	return out
}

// injectGodParse VodConfig.setParses：parses 非空时在首位插入超级解析。
func injectGodParse(api *model.Api) {
	if api == nil || len(api.Parses) == 0 {
		return
	}
	god := model.Parse{
		Name: "超级解析",
		Type: model.FlexInt{Valid: true, Value: 4},
	}
	api.Parses = append([]model.Parse{god}, api.Parses...)
}

// resolveSitePaths 将站点 api/ext/jar 相对路径解析为绝对 URL（站点路径解析）。
func resolveSitePaths(api *model.Api) {
	base := strings.TrimSpace(api.URL)
	spiderJar := strings.TrimSpace(api.Spider)
	for i := range api.Sites {
		site := &api.Sites[i]
		site.API = resolveSiteField(base, site.API)
		if ext := strings.TrimSpace(site.Ext.String()); ext != "" {
			site.Ext = model.FlexString(resolveSiteField(base, ext))
		}
		// Site.objectFrom：jar 空则继承根 spider。
		if strings.TrimSpace(site.Jar) == "" {
			site.Jar = spiderJar
		} else {
			site.Jar = resolveSiteField(base, site.Jar)
		}
	}
	// Live.objectFrom：直播 jar 空则继承根 spider。
	for i := range api.Lives {
		live := &api.Lives[i]
		if strings.TrimSpace(live.URL) != "" {
			live.URL = resolveSiteField(base, live.URL)
		}
		if strings.TrimSpace(live.API) != "" {
			live.API = resolveSiteField(base, live.API)
		}
		if ext := strings.TrimSpace(live.Ext.String()); ext != "" {
			live.Ext = model.FlexString(resolveSiteField(base, ext))
		}
		if strings.TrimSpace(live.JAR) == "" {
			live.JAR = spiderJar
		} else {
			live.JAR = resolveSiteField(base, live.JAR)
		}
	}
}

// resolveParsePaths Parse.getUrl → UrlUtil.convert：解析器 url 支持 assets/proxy/file/相对路径。
func resolveParsePaths(api *model.Api) {
	if api == nil {
		return
	}
	base := strings.TrimSpace(api.URL)
	for i := range api.Parses {
		p := &api.Parses[i]
		if u := strings.TrimSpace(p.URL); u != "" {
			p.URL = resolveSiteField(base, u)
		}
	}
}

// resolveApiAssets 解析配置根上的 logo/wallpaper/banner 相对路径（如 "../bing"、"../tencent/banners"）。
func resolveApiAssets(api *model.Api) {
	if api == nil {
		return
	}
	base := strings.TrimSpace(api.URL)
	if w := strings.TrimSpace(api.Wallpaper); w != "" {
		api.Wallpaper = resolveSiteField(base, w)
	}
	if logo := strings.TrimSpace(api.Logo); logo != "" {
		api.Logo = resolveSiteField(base, logo)
	}
	if banner := strings.TrimSpace(api.Banner); banner != "" {
		api.Banner = resolveSiteField(base, banner)
	}
}

func resolveSiteField(base, value string) string {
	value = strings.TrimSpace(value)
	if value == "" {
		return value
	}
	// 特殊 scheme 交给本地 HTTP 服务。
	localBase := fmt.Sprintf("http://127.0.0.1:%d", localproxy.Port())
	if strings.HasPrefix(value, "assets://") {
		return localBase + "/" + strings.TrimPrefix(value, "assets://")
	}
	if strings.HasPrefix(value, "proxy://") {
		return localBase + "/proxy?" + strings.TrimPrefix(value, "proxy://")
	}
	if strings.HasPrefix(value, "file://") {
		path := url.PathEscape(strings.TrimPrefix(value, "file://"))
		path = strings.ReplaceAll(path, "%2F", "/")
		return localBase + "/file/" + path
	}
	if strings.HasPrefix(value, "http://") || strings.HasPrefix(value, "https://") ||
		strings.HasPrefix(value, "csp_") {
		return value
	}
	// 纯 JSON/脚本正文不当 URL 解析
	if strings.HasPrefix(value, "{") || strings.HasPrefix(value, "[") || strings.Contains(value, "\n") {
		return value
	}
	// JAR 站常见 ext 为 Base64（如 csp_BD）。不会把它拼到配置根上；
	// 若误 ResolveRelativeURL，会变成带 ':' 的绝对 URL，随后 base64Decode 直接炸。
	if looksLikeBase64Payload(value) {
		return value
	}
	if base == "" {
		return value
	}
	if resolved := util.ResolveRelativeURL(base, value); resolved != "" {
		return resolved
	}
	return value
}

// looksLikeBase64Payload 识别不透明 Base64 载荷（无路径/扩展名语义）。
func looksLikeBase64Payload(s string) bool {
	if len(s) < 16 {
		return false
	}
	if strings.ContainsAny(s, ".:\\") || strings.Contains(s, "://") {
		return false
	}
	for i := 0; i < len(s); i++ {
		c := s[i]
		switch {
		case c >= 'A' && c <= 'Z', c >= 'a' && c <= 'z', c >= '0' && c <= '9':
		case c == '+', c == '/', c == '=', c == '-', c == '_':
		default:
			return false
		}
	}
	return true
}

func (m *Manager) Spider(site model.Site) spider.Spider {
	jar := site.Jar
	if jar == "" {
		jar = m.API().Spider
	}
	ext := site.Ext.String()
	spider.SetRecent(site.Key, site.API, ext, jar)
	return spider.Get(site.Key, site.API, ext, jar)
}

func (m *Manager) expandLives(api *model.Api) {
	if api == nil || len(api.Lives) == 0 {
		return
	}
	out := make([]model.Live, 0, len(api.Lives))
	for _, item := range api.Lives {
		if !isLiveIndexRef(item) {
			out = append(out, item)
			continue
		}
		url := resolveSiteField(api.URL, strings.TrimSpace(item.URL))
		fetched, err := fetchLiveArray(url)
		if err != nil || len(fetched) == 0 {
			if err != nil {
				log.Printf("fetch lives %s: %v", url, err)
			}
			item.URL = url
			out = append(out, item)
			continue
		}
		out = append(out, fetched...)
	}
	api.Lives = out
}

func isLiveIndexRef(l model.Live) bool {
	if strings.TrimSpace(l.Name) != "" || strings.TrimSpace(l.API) != "" {
		return false
	}
	u := strings.TrimSpace(l.URL)
	return looksLikeURL(u)
}

func fetchLiveArray(rawURL string) ([]model.Live, error) {
	text, err := util.HTTPGet(rawURL, nil)
	if err != nil {
		return nil, err
	}
	text = util.CleanJSONComments(text)
	var list model.LiveList
	if err := json.Unmarshal([]byte(strings.TrimSpace(text)), &list); err != nil {
		return nil, err
	}
	return []model.Live(list), nil
}

func (m *Manager) initLiveFromVod(cfg *database.Config, api *model.Api) {
	if cfg == nil || api == nil || len(api.Lives) == 0 {
		return
	}
	vodURL := strings.TrimSpace(cfg.URL)
	if vodURL == "" {
		return
	}
	name := strings.TrimSpace(cfg.Name)
	if m.db != nil {
		if _, err := m.db.UpsertConfig(&database.Config{
			Type: database.ConfigTypeLive,
			URL:  vodURL,
			Name: name,
		}); err != nil {
			log.Printf("persist live config %s: %v", vodURL, err)
		}
	}
	liveURL := strings.TrimSpace(settings.Get(settings.LIVE))
	oldVodURL := strings.TrimSpace(m.API().URL)
	// TV LiveConfig.needSync(url): sync || live 为空 || live URL == 新点播 URL。
	// sync 表示直播当前跟点播同一地址（换源前 live == 旧点播），换点播后仍要跟着切。
	if liveURL != "" && liveURL != oldVodURL && liveURL != vodURL {
		return
	}
	settings.Set(settings.LIVE, vodURL)
	_ = settings.Save()
}
