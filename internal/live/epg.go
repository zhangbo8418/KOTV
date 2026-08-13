package live

import (
	"bytes"
	"compress/gzip"
	"encoding/json"
	"encoding/xml"
	"fmt"
	"io"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"

	"github.com/bobo/KOTV/internal/model"
	"github.com/bobo/KOTV/internal/paths"
	"github.com/bobo/KOTV/internal/util"
)

// Epg 某日节目单。
type Epg struct {
	Key  string    `json:"key"`
	Date string    `json:"date"`
	List []EpgData `json:"list"`
}

// EpgData 单条节目。
type EpgData struct {
	Title     string `json:"title"`
	Start     string `json:"start"`
	End       string `json:"end"`
	StartTime int64  `json:"-"`
	EndTime   int64  `json:"-"`
}

func (d EpgData) IsInRange() bool {
	now := time.Now().UnixMilli()
	return d.StartTime <= now && now <= d.EndTime
}

func (d EpgData) Format() string {
	if d.Title == "" {
		return ""
	}
	if d.Start == "" && d.End == "" {
		return d.Title
	}
	return d.Start + " ~ " + d.End + "  " + d.Title
}

// IsFuture 是否未开始节目。
func (d EpgData) IsFuture() bool {
	return d.StartTime > time.Now().UnixMilli()
}

// Range RTSP rtsp_range。
func (d EpgData) Range() string {
	if d.StartTime == 0 {
		return ""
	}
	end := d.EndTime
	if end == 0 {
		end = d.StartTime + 30*60*1000
	}
	fmtUTC := func(ms int64) string {
		return time.UnixMilli(ms).UTC().Format("20060102T150405Z")
	}
	return "clock=" + fmtUTC(d.StartTime) + "-" + fmtUTC(end)
}

// SplitEpgURLs Live.getEpgApi / getEpgXml：逗号拆分模板 API 与 XMLTV 文件。
func SplitEpgURLs(epg string) (apiTemplate string, xmlURLs []string) {
	for _, part := range strings.Split(epg, ",") {
		part = strings.TrimSpace(part)
		if part == "" {
			continue
		}
		if strings.Contains(part, "{") {
			if apiTemplate == "" {
				apiTemplate = part
			}
			continue
		}
		low := strings.ToLower(part)
		if strings.Contains(low, "xml") || strings.HasSuffix(low, ".gz") || strings.HasPrefix(low, "http://") || strings.HasPrefix(low, "https://") {
			xmlURLs = append(xmlURLs, part)
		}
	}
	return apiTemplate, xmlURLs
}

// ChannelEPGSource 频道级或源级 EPG 原始串。
func ChannelEPGSource(ch *model.LiveChannel) string {
	if ch == nil {
		return ""
	}
	if strings.TrimSpace(ch.EPG) != "" {
		return strings.TrimSpace(ch.EPG)
	}
	if ch.Live != nil {
		return strings.TrimSpace(ch.Live.EPG)
	}
	return ""
}

// LoadChannelDays 按 TV 策略拉节目单：先模板 API，再 XMLTV。
func LoadChannelDays(ch *model.LiveChannel) []Epg {
	if ch == nil {
		return nil
	}
	src := ChannelEPGSource(ch)
	api, xmls := SplitEpgURLs(src)
	if api != "" {
		saved := ch.EPG
		ch.EPG = api
		out := LoadChannelEPG(ch)
		ch.EPG = saved
		if len(out) > 0 {
			return out
		}
	}
	for _, u := range xmls {
		days, logo, err := LoadXMLTVDays(u, ch)
		if err != nil || len(days) == 0 {
			continue
		}
		if logo != "" && !hasHTTPLogo(ch.Logo) {
			ch.Logo = logo
		}
		return days
	}
	// 兼容：整串无逗号且非模板时仍当 XMLTV。
	if api == "" && len(xmls) == 0 && src != "" && !strings.Contains(src, "{") {
		days, logo, err := LoadXMLTVDays(src, ch)
		if err == nil && len(days) > 0 {
			if logo != "" && !hasHTTPLogo(ch.Logo) {
				ch.Logo = logo
			}
			return days
		}
	}
	return nil
}

func hasHTTPLogo(s string) bool {
	s = strings.TrimSpace(strings.ToLower(s))
	return strings.HasPrefix(s, "http://") || strings.HasPrefix(s, "https://") || strings.HasPrefix(s, "data:")
}

// LoadChannelEPG 按模板拉取昨/今/明节目单。
func LoadChannelEPG(ch *model.LiveChannel) []Epg {
	if ch == nil {
		return nil
	}
	template := ch.EPG
	if template == "" && ch.Live != nil {
		template = ch.Live.EPG
	}
	api, _ := SplitEpgURLs(template)
	if api != "" {
		template = api
	}
	if template == "" || !strings.Contains(template, "{") {
		return nil
	}
	var out []Epg
	zone := time.Local
	for _, offset := range []int{-1, 0, 1} {
		date := time.Now().In(zone).AddDate(0, 0, offset).Format("2006-01-02")
		nameToken := ch.TvgName
		if nameToken == "" {
			nameToken = ch.Name
		}
		idToken := ch.TvgID
		if idToken == "" {
			idToken = nameToken
		}
		u := template
		u = strings.ReplaceAll(u, "{date}", date)
		u = strings.ReplaceAll(u, "{id}", url.QueryEscape(idToken))
		u = strings.ReplaceAll(u, "{name}", url.QueryEscape(nameToken))
		u = strings.ReplaceAll(u, "{epg}", ch.EPG)
		u = strings.ReplaceAll(u, "{logo}", ch.Logo)
		u = strings.ReplaceAll(u, "+", "%20")
		if !strings.HasPrefix(u, "http") {
			continue
		}
		text, err := util.HTTPGet(u, nil)
		if err != nil || text == "" {
			continue
		}
		epg := ParseEPG(text, idToken, date)
		if len(epg.List) > 0 {
			out = append(out, epg)
		}
	}
	return out
}

// ParseEPG 解析 JSON 或简易 XML 片段。
func ParseEPG(text, key, date string) Epg {
	text = strings.TrimSpace(text)
	if strings.HasPrefix(text, "{") {
		var dto struct {
			Key     string    `json:"key"`
			Date    string    `json:"date"`
			List    []EpgData `json:"list"`
			EpgData []EpgData `json:"epg_data"`
		}
		if err := json.Unmarshal([]byte(text), &dto); err == nil {
			list := dto.List
			if len(list) == 0 {
				list = dto.EpgData
			}
			epg := Epg{Key: key, Date: date, List: list}
			if dto.Key != "" {
				epg.Key = dto.Key
			}
			if dto.Date != "" {
				epg.Date = dto.Date
			}
			setEpgTimes(&epg)
			return epg
		}
	}
	// 简易 XML programme 片段（EpgParser.getEpg）
	if strings.Contains(text, "<programme") || strings.Contains(text, "<tv") {
		if days, _, err := matchXMLTVDays([]byte(text), &model.LiveChannel{TvgID: key, Name: key}, date); err == nil {
			for _, d := range days {
				if d.Date == date || date == "" {
					d.Key = key
					return d
				}
			}
			if len(days) > 0 {
				days[0].Key = key
				return days[0]
			}
		}
	}
	return Epg{Key: key, Date: date}
}

func setEpgTimes(epg *Epg) {
	for i := range epg.List {
		epg.List[i].StartTime = parseEpgTime(epg.Date + epg.List[i].Start)
		epg.List[i].EndTime = parseEpgTime(epg.Date + epg.List[i].End)
		if epg.List[i].StartTime > 0 && epg.List[i].EndTime == 0 {
 // 缺结束时间时按 30 分钟估，保证回看 playseek 能拼出区间。
			epg.List[i].EndTime = epg.List[i].StartTime + 30*60*1000
		}
		if epg.List[i].EndTime > 0 && epg.List[i].EndTime < epg.List[i].StartTime {
			epg.List[i].EndTime += 24 * 60 * 60 * 1000
		}
	}
}

func parseEpgTime(source string) int64 {
	source = strings.TrimSpace(source)
	layouts := []string{
		"2006-01-0215:04:05",
		"2006-01-0215:04",
		"20060102150405",
		"200601021504",
	}
	for _, layout := range layouts {
		s := source
		need := len(layout)
 // 去掉空格/连字符差异后再截断。
		if layout == "200601021504" || layout == "20060102150405" {
			compact := strings.Map(func(r rune) rune {
				if r >= '0' && r <= '9' {
					return r
				}
				return -1
			}, s)
			if len(compact) >= need {
				s = compact[:need]
			} else {
				continue
			}
		}
		if t, err := time.ParseInLocation(layout, s, time.Local); err == nil {
			return t.UnixMilli()
		}
	}
	return 0
}

// LoadXMLTVDays 下载 XMLTV，返回昨/今/明分桶，并尝试从 <icon> 回填 logo。
func LoadXMLTVDays(epgURL string, ch *model.LiveChannel) ([]Epg, string, error) {
	if epgURL == "" || ch == nil || strings.Contains(epgURL, "{") {
		return nil, "", nil
	}
	cacheDir := paths.EpgCache()
	cacheFile := filepath.Join(cacheDir, util.MD5(epgURL)+".xml")
	needFetch := true
	if st, err := os.Stat(cacheFile); err == nil {
		if time.Since(st.ModTime()) < 6*time.Hour {
			needFetch = false
		}
	}
	if needFetch {
		body, err := util.HTTPGetBytes(epgURL, nil)
		if err != nil {
			return nil, "", err
		}
		if strings.HasSuffix(strings.ToLower(epgURL), ".gz") || isGzip(body) {
			gr, err := gzip.NewReader(bytes.NewReader(body))
			if err == nil {
				unzipped, _ := io.ReadAll(gr)
				_ = gr.Close()
				body = unzipped
			}
		}
		_ = os.WriteFile(cacheFile, body, 0o644)
	}
	data, err := os.ReadFile(cacheFile)
	if err != nil {
		return nil, "", err
	}
	return matchXMLTVDays(data, ch, "")
}

func isGzip(b []byte) bool {
	return len(b) >= 2 && b[0] == 0x1f && b[1] == 0x8b
}

type xmltv struct {
	Channels   []xmlChannel   `xml:"channel"`
	Programmes []xmlProgramme `xml:"programme"`
}

type xmlChannel struct {
	ID           string   `xml:"id,attr"`
	DisplayNames []string `xml:"display-name"`
	Icon         xmlIcon  `xml:"icon"`
}

type xmlIcon struct {
	Src string `xml:"src,attr"`
}

type xmlProgramme struct {
	Start   string `xml:"start,attr"`
	Stop    string `xml:"stop,attr"`
	Channel string `xml:"channel,attr"`
	Title   string `xml:"title"`
}

func matchXMLTVDays(data []byte, ch *model.LiveChannel, preferDate string) ([]Epg, string, error) {
	var doc xmltv
	if err := xml.Unmarshal(data, &doc); err != nil {
		return nil, "", err
	}
	ids := map[string]bool{}
	for _, id := range []string{ch.TvgID, ch.TvgName, ch.Name} {
		if id != "" {
			ids[strings.ToLower(strings.TrimSpace(id))] = true
		}
	}
	// display-name → channel id 桥接（findTargetChannel）
	logo := ""
	for _, c := range doc.Channels {
		cid := strings.ToLower(strings.TrimSpace(c.ID))
		hit := ids[cid]
		if !hit {
			for _, dn := range c.DisplayNames {
				if ids[strings.ToLower(strings.TrimSpace(dn))] {
					hit = true
					break
				}
			}
		}
		if hit {
			ids[cid] = true
			if logo == "" && strings.TrimSpace(c.Icon.Src) != "" {
				logo = strings.TrimSpace(c.Icon.Src)
			}
		}
	}

	byDay := map[string][]EpgData{}
	zone := time.Local
	now := time.Now().In(zone)
	minDay := time.Date(now.Year(), now.Month(), now.Day(), 0, 0, 0, 0, zone).AddDate(0, 0, -1)
	maxDay := minDay.Add(3 * 24 * time.Hour)
	for _, p := range doc.Programmes {
		if !ids[strings.ToLower(strings.TrimSpace(p.Channel))] {
			continue
		}
		st := parseXMLTVTime(p.Start)
		et := parseXMLTVTime(p.Stop)
		if st.IsZero() {
			continue
		}
		if et.Before(minDay) || st.After(maxDay) {
			continue
		}
		date := st.In(zone).Format("2006-01-02")
		if preferDate != "" && date != preferDate {
			continue
		}
		byDay[date] = append(byDay[date], EpgData{
			Title:     p.Title,
			Start:     st.In(zone).Format("15:04"),
			End:       et.In(zone).Format("15:04"),
			StartTime: st.UnixMilli(),
			EndTime:   et.UnixMilli(),
		})
	}
	var out []Epg
	for _, offset := range []int{-1, 0, 1} {
		date := now.AddDate(0, 0, offset).Format("2006-01-02")
		if list := byDay[date]; len(list) > 0 {
			out = append(out, Epg{Key: ch.TvgID, Date: date, List: list})
		}
	}
	if len(out) == 0 {
		for date, list := range byDay {
			out = append(out, Epg{Key: ch.TvgID, Date: date, List: list})
		}
	}
	return out, logo, nil
}

func parseXMLTVTime(s string) time.Time {
	s = strings.TrimSpace(s)
	if len(s) >= 14 {
		t, err := time.ParseInLocation("20060102150405", s[:14], time.Local)
		if err == nil {
			return t
		}
	}
	return time.Time{}
}

// FormatCatchup 根据 Catchup 规则生成回看 URL（回看地址格式化）。
func FormatCatchup(url string, cp model.Catchup, prog EpgData) string {
	if cp.IsEmpty() || prog.StartTime == 0 {
		return ""
	}
	end := prog.EndTime
	if end == 0 {
		end = prog.StartTime + 30*60*1000
	}
	result := replaceCatchupTokens(cp.Source, prog.StartTime, end)
	if cp.Type == "default" {
		return result
	}
	return appendCatchup(url, result, cp.Replace)
}

// ResolveCatchupURL LiveApi.getUrl(channel, epg)：先取真实播放地址，再 format。
func ResolveCatchupURL(s *Service, ch *model.LiveChannel, prog EpgData) (string, map[string]string, error) {
	if ch == nil {
		return "", nil, fmt.Errorf("频道为空")
	}
	if prog.StartTime == 0 {
		return "", nil, fmt.Errorf("节目时间无效")
	}
	if prog.IsFuture() {
		return "", nil, fmt.Errorf("尚未播出")
	}

	var (
		base    string
		headers map[string]string
		err     error
	)
	if s != nil {
		base, headers, err = s.ResolvePlayURLParsed(ch)
		if err != nil || base == "" {
			base, headers = ResolvePlayURL(ch)
		}
	} else {
		base, headers = ResolvePlayURL(ch)
	}
	if base == "" {
		return "", headers, fmt.Errorf("无播放地址")
	}

	cp := ch.CatchupRule()
	// 解析后地址才是 PLTV 时，补默认规则（是否支持回看）。
	if cp.IsEmpty() && (strings.Contains(base, "/PLTV/") || strings.Contains(ch.CurrentURL(), "/PLTV/")) {
 cp = model.CatchupPLTV()
	}
	if cp.Regex != "" && !cp.Match(base) && !cp.Match(ch.CurrentURL()) {
		return "", headers, fmt.Errorf("该源不支持回看")
	}
	// 回看地址格式化(realUrl)：format 必须作用在带 PLTV 的地址上，
	// 否则只给直播地址拼 playseek，播放器会一直缓冲。
	formatBase := base
	if cp.Regex != "" && !cp.Match(formatBase) && cp.Match(ch.CurrentURL()) {
		if raw, _ := ResolvePlayURL(ch); raw != "" {
			formatBase = raw
		} else {
			formatBase = ch.CurrentURL()
		}
	}
	catchURL := FormatCatchup(formatBase, cp, prog)
	if catchURL == "" {
		return "", headers, fmt.Errorf("该源不支持回看")
	}
	if headers == nil {
		headers = map[string]string{}
	}
	if strings.HasPrefix(strings.ToLower(base), "rtsp://") || strings.HasPrefix(strings.ToLower(ch.CurrentURL()), "rtsp://") {
		if r := prog.Range(); r != "" {
			headers["rtsp_range"] = r
		}
	}
	return catchURL, headers, nil
}

var catchupTokenRe = regexp.MustCompile(`\$?\{[^}]*\}`)

func replaceCatchupTokens(src string, start, end int64) string {
	return catchupTokenRe.ReplaceAllStringFunc(src, func(token string) string {
		i := strings.Index(token, "{")
		j := strings.LastIndex(token, "}")
		if i < 0 || j <= i {
			return ""
		}
		return formatCatchupToken(token[i+1:j], start, end)
	})
}

func formatCatchupToken(tag string, start, end int64) string {
	if strings.HasPrefix(tag, "(b") {
		if idx := strings.Index(tag, ")"); idx >= 0 {
			return formatMillis(start, tag[idx+1:])
		}
	}
	if strings.HasPrefix(tag, "(e") {
		if idx := strings.Index(tag, ")"); idx >= 0 {
			return formatMillis(end, tag[idx+1:])
		}
	}
	if strings.HasPrefix(tag, "utcend:") {
		return fmt.Sprintf("%d", end/1000)
	}
	if strings.HasPrefix(tag, "utc:") {
		return fmt.Sprintf("%d", start/1000)
	}
	return ""
}

func formatMillis(ms int64, fmtStr string) string {
	if fmtStr == "timestamp" {
		return fmt.Sprintf("%d", ms/1000)
	}
	zone := time.Local
	f := fmtStr
	// 部分源写 {(b)yyyyMMddHHmmss:utc}，按 UTC 输出。
	if i := strings.Index(f, ":"); i >= 0 {
		mod := strings.ToLower(strings.TrimSpace(f[i+1:]))
		f = f[:i]
		if mod == "utc" || mod == "gmt" {
			zone = time.UTC
		}
	}
	t := time.UnixMilli(ms).In(zone)
	goFmt := xmlTVFmtToGo(f)
	return t.Format(goFmt)
}

// xmlTVFmtToGo 将 Java DateTimeFormatter / IPTV playseek 常用图案转为 Go 布局。
// 注意：不少直播源误把秒写成 SS（Java 里 SS=小数秒）；对 playseek 一律按整秒处理。
func xmlTVFmtToGo(f string) string {
	var b strings.Builder
	b.Grow(len(f) + 8)
	for i := 0; i < len(f); {
 // 优先匹配长 token，避免 MM/mm、ss/SS 互相干扰。
		switch {
		case strings.HasPrefix(f[i:], "yyyy"):
			b.WriteString("2006")
			i += 4
		case strings.HasPrefix(f[i:], "yy"):
			b.WriteString("06")
			i += 2
		case strings.HasPrefix(f[i:], "MM"):
			b.WriteString("01")
			i += 2
		case strings.HasPrefix(f[i:], "dd"):
			b.WriteString("02")
			i += 2
		case strings.HasPrefix(f[i:], "HH"), strings.HasPrefix(f[i:], "hh"):
			b.WriteString("15")
			i += 2
		case strings.HasPrefix(f[i:], "mm"):
			b.WriteString("04")
			i += 2
		case strings.HasPrefix(f[i:], "ss"), strings.HasPrefix(f[i:], "SS"):
 // ss=秒；SS 在正规 Java 图案是小数秒，但 IPTV playseek 几乎都当秒用。
			b.WriteString("05")
			i += 2
		case strings.HasPrefix(f[i:], "SSS"):
			b.WriteString("000")
			i += 3
		default:
			b.WriteByte(f[i])
			i++
		}
	}
	return b.String()
}

func appendCatchup(url, suffix, replace string) string {
	output := url
	if parts := strings.SplitN(replace, ",", 2); len(parts) == 2 {
 // 使用 String.replaceAll（正则）； 用字面替换。优先正则，失败再字面。
		if re, err := regexp.Compile(parts[0]); err == nil {
			output = re.ReplaceAllString(output, parts[1])
		} else {
			output = strings.Replace(output, parts[0], parts[1], 1)
		}
	}
	if strings.Contains(output, "?") {
		suffix = strings.Replace(suffix, "?", "&", 1)
	}
	return output + suffix
}
