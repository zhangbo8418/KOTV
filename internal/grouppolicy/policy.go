package grouppolicy

import (
	"fmt"
	"strings"
	"sync"
	"time"

	"github.com/bobo/KOTV/internal/auth"
	"github.com/bobo/KOTV/internal/database"
	"github.com/bobo/KOTV/internal/model"
	"github.com/bobo/KOTV/internal/settings"
)

var (
	mu  sync.Mutex
	store *database.DB
)

func BindDB(db *database.DB) { store = db }

func db() *database.DB { return store }

// Bundle 某用户/本机会话解析后的策略包。
type Bundle struct {
	GroupID      string
	IsAdmin      bool
	VodConfigIDs map[int64]struct{}
	VodURLs      map[string]struct{}
	Lives        []database.GroupLive
	SiteHide     map[string]struct{}
	Settings     map[string]string
	Caps         map[string]bool
	Notices      []map[string]any
	Maintenance  bool
	MaintMsg     string
	ForceUpdate  bool
	MinVersion   string
	UpdateURL    string
	Brand        map[string]string
}

func Resolve(user *auth.User) Bundle {
	b := Bundle{
		GroupID:      database.DefaultGroupID,
		VodConfigIDs: map[int64]struct{}{},
		VodURLs:      map[string]struct{}{},
		SiteHide:     map[string]struct{}{},
		Settings:     map[string]string{},
		Caps:         defaultCaps(),
		Brand:        map[string]string{},
	}
	d := db()
	if d == nil {
		return b
	}
	if user != nil {
		b.IsAdmin = user.Role == auth.RoleAdmin
		if user.GroupID != "" {
			b.GroupID = user.GroupID
		}
	}
	ids, _ := d.ListGroupVodIDs(b.GroupID)
	for _, id := range ids {
		b.VodConfigIDs[id] = struct{}{}
		if c, err := d.GetConfigByID(id); err == nil && c != nil {
			u := strings.TrimSpace(c.URL)
			if u != "" {
				b.VodURLs[u] = struct{}{}
			}
		}
	}
	// 默认组若尚无勾选（极端空库），放行全部仓以免本机不可用
	if len(b.VodURLs) == 0 && b.GroupID == database.DefaultGroupID {
		if cfgs, err := d.ListConfigs(int64(database.ConfigTypeSite)); err == nil {
			for _, c := range cfgs {
				b.VodConfigIDs[c.ID] = struct{}{}
				u := strings.TrimSpace(c.URL)
				if u != "" {
					b.VodURLs[u] = struct{}{}
				}
			}
		}
	}
	lives, _ := d.ListGroupLives(b.GroupID)
	for _, l := range lives {
		if l.Enabled {
			b.Lives = append(b.Lives, l)
		}
	}
	hides, _ := d.ListGroupSiteHides(b.GroupID)
	for _, k := range hides {
		b.SiteHide[k] = struct{}{}
	}
	gs, _ := d.ListGroupSettings(b.GroupID)
	b.Settings = gs
	applyCaps(&b, gs)
	b.UpdateURL = strings.TrimSpace(gs["updateUrl"])
	if b.UpdateURL == "" {
		b.UpdateURL = strings.TrimSpace(settings.Get(settings.UpdateURL))
	}
	b.MinVersion = firstNonEmpty(gs["minClientVersion"], settings.Get(settings.Type("minClientVersion")))
	b.ForceUpdate = truthy(gs["forceUpdate"]) || truthy(settings.Get(settings.Type("forceUpdate")))
	b.Maintenance = truthy(gs["maintenance"]) || truthy(settings.Get(settings.Type("maintenance")))
	b.MaintMsg = firstNonEmpty(gs["maintenanceMsg"], settings.Get(settings.Type("maintenanceMsg")))
	for _, k := range []string{"wallpaper", "logo", "banner", "aboutUrl", "supportUrl", "footer", "welcome"} {
		if v := strings.TrimSpace(gs[k]); v != "" {
			b.Brand[k] = v
		} else if v := strings.TrimSpace(settings.Get(settings.Type(k))); v != "" {
			b.Brand[k] = v
		}
	}
	b.Notices = activeNotices(d, user, b.GroupID)
	return b
}

func defaultCaps() map[string]bool {
	return map[string]bool{
		"allowAddRepo":       false,
		"allowDownload":      true,
		"allowBt":            true,
		"allowLive":          true,
		"allowDanmakuSearch": true,
		"allowRemoteControl": true,
		"allowCast":          true,
		"allowDlna":          true,
		"allowPip":           true,
		"allowBgPlay":        true,
		"allowSearch":        true,
		"allowKeep":          true,
		"allowHistory":       true,
		"forceIncognito":     false,
		"allowSync":          true,
	}
}

func applyCaps(b *Bundle, gs map[string]string) {
	for k := range b.Caps {
		if v, ok := gs[k]; ok && strings.TrimSpace(v) != "" {
			b.Caps[k] = truthy(v)
		}
	}
}

func truthy(s string) bool {
	s = strings.TrimSpace(strings.ToLower(s))
	return s == "1" || s == "true" || s == "yes" || s == "on"
}

func firstNonEmpty(a, b string) string {
	if strings.TrimSpace(a) != "" {
		return strings.TrimSpace(a)
	}
	return strings.TrimSpace(b)
}

func activeNotices(d *database.DB, user *auth.User, groupID string) []map[string]any {
	list, err := d.ListAdminNotices()
	if err != nil {
		return nil
	}
	now := time.Now().UnixMilli()
	uid := ""
	if user != nil {
		uid = user.ID
	}
	var out []map[string]any
	for _, n := range list {
		if n.StartsAt > 0 && now < n.StartsAt {
			continue
		}
		if n.EndsAt > 0 && now > n.EndsAt {
			continue
		}
		ok := false
		switch n.Scope {
		case "all":
			ok = true
		case "group":
			ok = n.TargetID == groupID
		case "user":
			ok = uid != "" && n.TargetID == uid
		}
		if !ok {
			continue
		}
		if n.Sticky && uid != "" && d.NoticeAcked(uid, n.ID) {
			continue
		}
		out = append(out, map[string]any{
			"id": n.ID, "kind": n.Kind, "title": n.Title, "body": n.Body,
			"link": n.Link, "sticky": n.Sticky, "priority": n.Priority,
		})
	}
	return out
}

// AllowVodURL 非 admin 只能用组内勾选仓。
func (b Bundle) AllowVodURL(url string) bool {
	if b.IsAdmin {
		return true
	}
	url = strings.TrimSpace(url)
	if url == "" {
		return false
	}
	_, ok := b.VodURLs[url]
	return ok
}

// FilterSites 去掉隐藏站（admin 豁免，便于管理台勾选）。
func (b Bundle) FilterSites(sites []model.Site) []model.Site {
	if b.IsAdmin || len(b.SiteHide) == 0 {
		return sites
	}
	out := make([]model.Site, 0, len(sites))
	for _, s := range sites {
		if _, hide := b.SiteHide[s.Key]; hide {
			continue
		}
		out = append(out, s)
	}
	return out
}

// InjectLives 用组直播列表覆盖 Api.Lives。
func (b Bundle) InjectLives(api *model.Api) {
	if api == nil {
		return
	}
	if !b.Caps["allowLive"] {
		api.Lives = nil
		return
	}
	lives := make(model.LiveList, 0, len(b.Lives))
	for _, l := range b.Lives {
		url := strings.TrimSpace(l.URL)
		if url == "" {
			continue
		}
		name := strings.TrimSpace(l.Name)
		if name == "" {
			name = url
		}
		lives = append(lives, model.Live{Name: name, URL: url})
	}
	api.Lives = lives
}

// PolicyDTO 下发给客户端的策略字段。
func (b Bundle) PolicyDTO() map[string]any {
	notices := b.Notices
	if notices == nil {
		notices = []map[string]any{}
	}
	return map[string]any{
		"groupId":          b.GroupID,
		"caps":             b.Caps,
		"notices":          notices,
		"maintenance":      b.Maintenance,
		"maintenanceMsg":   b.MaintMsg,
		"forceUpdate":      b.ForceUpdate,
		"minClientVersion": b.MinVersion,
		"updateUrl":        b.UpdateURL,
		"brand":            b.Brand,
	}
}

// FilterRepoList 过滤点播仓列表项（含 url 字段的 map）。
func (b Bundle) FilterRepoMaps(repos []map[string]any) []map[string]any {
	if b.IsAdmin {
		return repos
	}
	out := make([]map[string]any, 0, len(repos))
	for _, r := range repos {
		u, _ := r["url"].(string)
		if b.AllowVodURL(u) {
			out = append(out, r)
		}
	}
	return out
}

// AccessDeny 策略闸门拒绝原因（空=放行）。
func (b Bundle) AccessDeny(user *auth.User, clientIP string) (reason, code string) {
	if b.IsAdmin {
		return "", ""
	}
	if user != nil {
		if user.Status == "pending" {
			return "账号待审批", "pending"
		}
		if user.Status == "disabled" || !user.Enabled {
			return "账号已禁用", "disabled"
		}
		if user.ExpiresAt > 0 && time.Now().UnixMilli() > user.ExpiresAt {
			return "账号已到期", "expired"
		}
	}
	if d := db(); d != nil && b.GroupID != "" {
		if g, err := d.GetAuthGroup(b.GroupID); err == nil && g != nil && !g.Enabled {
			return "分组已停用", "group_disabled"
		}
	}
	if b.Maintenance {
		msg := b.MaintMsg
		if msg == "" {
			msg = "系统维护中"
		}
		return msg, "maintenance"
	}
	if deny := checkIPLists(b.Settings, clientIP); deny != "" {
		return deny, "ip"
	}
	if deny := checkAccessHours(b.Settings); deny != "" {
		return deny, "hours"
	}
	return "", ""
}

func checkIPLists(gs map[string]string, ip string) string {
	ip = strings.TrimSpace(ip)
	if ip == "" {
		return ""
	}
	deny := splitCSV(firstNonEmpty(gs["ipDeny"], settings.Get(settings.Type("ipDeny"))))
	for _, d := range deny {
		if d != "" && (ip == d || strings.HasPrefix(ip, d)) {
			return "IP 不允许访问"
		}
	}
	allow := splitCSV(firstNonEmpty(gs["ipAllow"], settings.Get(settings.Type("ipAllow"))))
	if len(allow) == 0 {
		return ""
	}
	for _, a := range allow {
		if a != "" && (ip == a || strings.HasPrefix(ip, a)) {
			return ""
		}
	}
	return "IP 不在允许列表"
}

// accessHours 格式示例：1-5=09:00-22:00 或 0-6=00:00-23:59（周日=0）；多段用分号。
func checkAccessHours(gs map[string]string) string {
	spec := strings.TrimSpace(firstNonEmpty(gs["accessHours"], settings.Get(settings.Type("accessHours"))))
	if spec == "" {
		return ""
	}
	now := time.Now()
	wd := int(now.Weekday()) // 0=Sun
	matchedDay := false
	for _, p := range strings.Split(spec, ";") {
		p = strings.TrimSpace(p)
		if p == "" {
			continue
		}
		dayPart, timePart, ok := splitHoursSpec(p)
		if !ok {
			continue
		}
		if !dayInRange(wd, dayPart) {
			continue
		}
		matchedDay = true
		if !timeInRange(now, timePart) {
			return "当前不在允许访问时段"
		}
		return ""
	}
	if matchedDay {
		return ""
	}
	// 有配置但今天不在任何 dayRange：拒绝
	return "当前不在允许访问时段"
}

func splitHoursSpec(p string) (dayPart, timePart string, ok bool) {
	if i := strings.IndexByte(p, '='); i > 0 {
		return strings.TrimSpace(p[:i]), strings.TrimSpace(p[i+1:]), true
	}
	// 兼容 1-5:09:00-22:00：在第一个 HH:MM 前切开
	for i := 0; i < len(p)-4; i++ {
		if p[i] == ':' && i+1 < len(p) && p[i+1] >= '0' && p[i+1] <= '9' {
			before := p[:i]
			if strings.ContainsAny(before, "0123456789") {
				return strings.TrimSpace(before), strings.TrimSpace(p[i+1:]), true
			}
		}
	}
	return "", "", false
}

func dayInRange(wd int, spec string) bool {
	spec = strings.TrimSpace(spec)
	if spec == "" {
		return true
	}
	if strings.Contains(spec, "-") {
		var a, b int
		fmt.Sscanf(spec, "%d-%d", &a, &b)
		if a <= b {
			return wd >= a && wd <= b
		}
		return wd >= a || wd <= b
	}
	var d int
	fmt.Sscanf(spec, "%d", &d)
	return wd == d
}

func timeInRange(now time.Time, spec string) bool {
	spec = strings.TrimSpace(spec)
	// HH:MM-HH:MM
	parts := strings.Split(spec, "-")
	if len(parts) != 2 {
		return true
	}
	parse := func(s string) (int, int, bool) {
		var h, m int
		_, err := fmt.Sscanf(strings.TrimSpace(s), "%d:%d", &h, &m)
		return h, m, err == nil
	}
	h1, m1, ok1 := parse(parts[0])
	h2, m2, ok2 := parse(parts[1])
	if !ok1 || !ok2 {
		return true
	}
	cur := now.Hour()*60 + now.Minute()
	start := h1*60 + m1
	end := h2*60 + m2
	if start <= end {
		return cur >= start && cur <= end
	}
	return cur >= start || cur <= end
}

func splitCSV(s string) []string {
	if strings.TrimSpace(s) == "" {
		return nil
	}
	raw := strings.FieldsFunc(s, func(r rune) bool { return r == ',' || r == ';' || r == '\n' })
	out := make([]string, 0, len(raw))
	for _, x := range raw {
		x = strings.TrimSpace(x)
		if x != "" {
			out = append(out, x)
		}
	}
	return out
}

// DeviceLimit 组/全局 maxDevices；0=不限。
func (b Bundle) DeviceLimit() int {
	v := strings.TrimSpace(firstNonEmpty(b.Settings["maxDevices"], settings.Get(settings.Type("maxDevices"))))
	if v == "" {
		return 0
	}
	var n int
	fmt.Sscanf(v, "%d", &n)
	return n
}

// SessionLimit 同账号并发会话上限；0=不限。
func (b Bundle) SessionLimit() int {
	v := strings.TrimSpace(firstNonEmpty(b.Settings["maxSessions"], settings.Get(settings.Type("maxSessions"))))
	if v == "" {
		return 0
	}
	var n int
	fmt.Sscanf(v, "%d", &n)
	return n
}

var _ = mu // silence if unused in future
