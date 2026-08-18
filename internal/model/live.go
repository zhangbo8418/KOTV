package model

import (
	"encoding/json"
	"regexp"
	"strings"
)

// Live 直播源配置。
type Live struct {
	Name       string     `json:"name"`
	Type       FlexInt    `json:"type"`
	URL        string     `json:"url"`
	API        string     `json:"api"`
	Ext        FlexString `json:"ext"` // 兼容 string / object / array（如 XtreamCode、MQiTV）
	JAR        string     `json:"jar"`
	EPG        string     `json:"epg"`
	Logo       string     `json:"logo"`
	UA         string     `json:"ua"`
	Referer    string     `json:"referer"`
	Origin     string     `json:"origin"`
	PlayerType FlexInt    `json:"playerType"`
	Header     FlexHeader `json:"header"`
	Catchup    Catchup    `json:"catchup"`
	Core       json.RawMessage `json:"core,omitempty"`
	Groups     []LiveGroup `json:"-"`
}

// SplitGroupPass 解析分组名「显示名_密码」：最后一个 _ 之后为密码。
func SplitGroupPass(raw string) (name, pass string) {
	if i := strings.LastIndex(raw, "_"); i >= 0 {
		pass = raw[i+1:]
		if pass != "" {
			return raw[:i], pass
		}
	}
	return raw, ""
}

func (l *Live) FindGroup(raw string) *LiveGroup {
	name, pass := SplitGroupPass(raw)
	for i := range l.Groups {
		if l.Groups[i].Name == name && l.Groups[i].Pass == pass {
			return &l.Groups[i]
		}
	}
	l.Groups = append(l.Groups, LiveGroup{Name: name, Pass: pass})
	return &l.Groups[len(l.Groups)-1]
}

func (l *Live) Headers() map[string]string {
	m := make(map[string]string)
	for k, v := range l.Header {
		m[k] = v
	}
	if l.UA != "" {
		m["User-Agent"] = l.UA
	}
	if l.Referer != "" {
		m["Referer"] = l.Referer
	}
	if l.Origin != "" {
		m["Origin"] = l.Origin
	}
	return m
}

// LiveGroup 频道分组。
type LiveGroup struct {
	Name     string
	Pass     string
	Channels []LiveChannel
}

func (g *LiveGroup) FindChannel(name string) *LiveChannel {
	for i := range g.Channels {
		if g.Channels[i].Name == name {
			return &g.Channels[i]
		}
	}
	g.Channels = append(g.Channels, LiveChannel{Name: name})
	return &g.Channels[len(g.Channels)-1]
}

// LiveChannel 直播频道。
type LiveChannel struct {
	Name     string
	Logo     string
	Number   string
	TvgID    string
	TvgName  string
	EPG      string
	Parse    int
	UA       string
	Referer  string
	Origin   string
	URLs     []string
	URLIndex int
	Header   map[string]string
	Format   string
	Drm      *Drm
	Catchup  *Catchup
	Live     *Live
}

func (c *LiveChannel) CurrentURL() string {
	if len(c.URLs) == 0 {
		return ""
	}
	idx := c.URLIndex
	if idx < 0 || idx >= len(c.URLs) {
		idx = 0
	}
	raw := c.URLs[idx]
	if i := indexByte(raw, '$'); i >= 0 {
		return trimSpace(raw[:i])
	}
	return trimSpace(raw)
}

func (c *LiveChannel) HasMultipleLines() bool { return len(c.URLs) > 1 }

// IsLastLine 是否已是最后一条线路（是否最后一条线路）。
func (c *LiveChannel) IsLastLine() bool {
	if c == nil || len(c.URLs) == 0 {
		return true
	}
	return c.URLIndex >= len(c.URLs)-1
}

func (c *LiveChannel) SwitchLine(next bool) {
	if len(c.URLs) == 0 {
		return
	}
	step := 1
	if !next {
		step = -1
	}
	c.URLIndex = (c.URLIndex + step + len(c.URLs)) % len(c.URLs)
}

func (c *LiveChannel) LineLabel() string {
	if !c.HasMultipleLines() {
		return ""
	}
	raw := c.URLs[c.URLIndex]
	if i := indexByte(raw, '$'); i >= 0 && i+1 < len(raw) {
		return raw[i+1:]
	}
	return "线路 " + itoa(c.URLIndex+1)
}

func (c *LiveChannel) ApplyLive(live *Live) {
	c.Live = live
	if c.UA == "" && live.UA != "" {
		c.UA = live.UA
	}
	if c.Referer == "" && live.Referer != "" {
		c.Referer = live.Referer
	}
	if c.Origin == "" && live.Origin != "" {
		c.Origin = live.Origin
	}
	if c.EPG == "" && live.EPG != "" {
		c.EPG = live.EPG
	}
	if len(c.Header) == 0 && len(live.Header) > 0 {
		c.Header = make(map[string]string)
		for k, v := range live.Header {
			c.Header[k] = v
		}
	}
	if c.Catchup == nil && !live.Catchup.IsEmpty() {
		cp := live.Catchup
		c.Catchup = &cp
	}
	// live.logo 模板（含 {id}/{name}）展开到频道 logo。
	logoTemplate := live.Logo
	if containsBrace(logoTemplate) && !hasHTTPPrefix(c.Logo) {
		nameToken := c.TvgName
		if nameToken == "" {
			nameToken = c.Name
		}
		idToken := c.TvgID
		if idToken == "" {
			idToken = nameToken
		}
		c.Logo = strings.NewReplacer(
			"{id}", idToken,
			"{name}", nameToken,
			"{logo}", c.Logo,
		).Replace(logoTemplate)
	}
}

// ResolvedLogo 返回可加载的 logo URL（已展开模板）。
func (c *LiveChannel) ResolvedLogo() string {
	if c == nil {
		return ""
	}
	if hasHTTPPrefix(c.Logo) {
		return c.Logo
	}
	if c.Live == nil || !containsBrace(c.Live.Logo) {
		return c.Logo
	}
	nameToken := c.TvgName
	if nameToken == "" {
		nameToken = c.Name
	}
	idToken := c.TvgID
	if idToken == "" {
		idToken = nameToken
	}
	return strings.NewReplacer(
		"{id}", idToken,
		"{name}", nameToken,
		"{logo}", c.Logo,
	).Replace(c.Live.Logo)
}

// CatchupPLTV() PLTV 回看规则。
func CatchupPLTV() Catchup {
	return Catchup{
		Type:    "append",
		Days:    "7",
		Regex:   "/PLTV/",
		Replace: "/PLTV/,/TVOD/",
		Source:  "?playseek=${(b)yyyyMMddHHmmss}-${(e)yyyyMMddHHmmss}",
	}
}

// CatchupRule 频道/源级回看规则；PLTV 自动补默认规则（是否支持回看）。
func (c *LiveChannel) CatchupRule() Catchup {
	if c == nil {
		return Catchup{}
	}
	if c.Catchup != nil && !c.Catchup.IsEmpty() {
		return *c.Catchup
	}
	if c.Live != nil && !c.Live.Catchup.IsEmpty() {
		return c.Live.Catchup
	}
	if strings.Contains(c.CurrentURL(), "/PLTV/") {
		return CatchupPLTV()
	}
	return Catchup{}
}

// HasCatchup 是否支持回看：有 regex 则匹配当前线路，否则看 source 非空。
func (c *LiveChannel) HasCatchup() bool {
	if c == nil {
		return false
	}
	cp := c.CatchupRule()
	if cp.Regex != "" {
		return cp.Match(c.CurrentURL())
	}
	return !cp.IsEmpty()
}

func hasHTTPPrefix(s string) bool {
	return len(s) >= 7 && (s[:7] == "http://" || (len(s) >= 8 && s[:8] == "https://"))
}

func (c *LiveChannel) BuildHeaders() map[string]string {
	m := make(map[string]string)
	if c.Live != nil {
		for k, v := range c.Live.Header {
			m[k] = v
		}
	}
	for k, v := range c.Header {
		m[k] = v
	}
	ua := c.UA
	if ua == "" && c.Live != nil {
		ua = c.Live.UA
	}
	if ua != "" {
		m["User-Agent"] = ua
	}
	ref := c.Referer
	if ref == "" && c.Live != nil {
		ref = c.Live.Referer
	}
	if ref != "" {
		m["Referer"] = ref
	}
	origin := c.Origin
	if origin == "" && c.Live != nil {
		origin = c.Live.Origin
	}
	if origin != "" {
		m["Origin"] = origin
	}
	return m
}

// Catchup 时移回看规则。
type Catchup struct {
	Type    string `json:"type"`
	Source  string `json:"source"`
	Replace string `json:"replace"`
	Regex   string `json:"regex"`
	Days    string `json:"days"`
}

// IsEmpty ：仅 source 为空即空（type/replace/regex 不算有规则）。
func (c Catchup) IsEmpty() bool {
	return strings.TrimSpace(c.Source) == ""
}

// Match contains 或正则命中。
func (c Catchup) Match(url string) bool {
	if c.Regex == "" {
		return false
	}
	if strings.Contains(url, c.Regex) {
		return true
	}
	re, err := regexp.Compile(c.Regex)
	if err != nil {
		return false
	}
	return re.FindStringIndex(url) != nil
}

func CatchupDecide(item, fallback Catchup) Catchup {
	if !item.IsEmpty() {
		return item
	}
	return fallback
}

func indexByte(s string, c byte) int {
	for i := 0; i < len(s); i++ {
		if s[i] == c {
			return i
		}
	}
	return -1
}

func trimSpace(s string) string {
	for len(s) > 0 && (s[0] == ' ' || s[0] == '\t') {
		s = s[1:]
	}
	for len(s) > 0 && (s[len(s)-1] == ' ' || s[len(s)-1] == '\t') {
		s = s[:len(s)-1]
	}
	return s
}

func containsBrace(s string) bool {
	for i := 0; i < len(s); i++ {
		if s[i] == '{' {
			return true
		}
	}
	return false
}

func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	neg := n < 0
	if neg {
		n = -n
	}
	var b [20]byte
	i := len(b)
	for n > 0 {
		i--
		b[i] = byte('0' + n%10)
		n /= 10
	}
	if neg {
		i--
		b[i] = '-'
	}
	return string(b[i:])
}
