package parse

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"regexp"
	"strings"
	"sync"
	"time"

	"github.com/bobo/KOTV/internal/localproxy"
	"github.com/bobo/KOTV/internal/model"
	"github.com/bobo/KOTV/internal/spider"
	"github.com/bobo/KOTV/internal/util"
)

// Options 二次解析上下文。
type Options struct {
	Parses    []model.Parse
	Flags     []string
	Rules     []model.Rule
	Jar       string
	Flag      string
	Click     string // 结果自带 click
	SiteClick string // 对齐 TV ParseJob.getClick：站点 click 优先
	Prefer    string // 用户指定解析器名称（空=自动）
	IsVideo   func(string) bool // 对齐 TV CustomWebView：站点自定义 isVideo
}

// AnnotateParseErr 避免「解析失败: 解析失败: …」重复包装。
func AnnotateParseErr(err error) error {
	if err == nil {
		return nil
	}
	if strings.Contains(err.Error(), "解析失败") {
		return err
	}
	return fmt.Errorf("解析失败: %w", err)
}

// NeedParse 是否需要二次解析。
func NeedParse(r model.Result) bool {
	if r.Parse.Is(1) {
		return true
	}
	if r.Jx.Is(1) {
		return true
	}
	return false
}

// HasParse 配置里是否有可用解析器。
func HasParse(parses []model.Parse) bool {
	return len(parses) > 0
}

// IsUseParse 是否应使用全局解析器（需配置里确有 parses）。
func IsUseParse(r model.Result, flags []string, parses []model.Parse) bool {
	if !HasParse(parses) {
		return false
	}
	if r.Jx.Is(1) {
		return true
	}
	if strings.TrimSpace(r.PlayURL) != "" {
		return false
	}
	if r.Flag == "" || len(flags) == 0 {
		return false
	}
	for _, f := range flags {
		if f == r.Flag {
			return true
		}
	}
	return false
}

// ShouldShowParseUI 播放控制是否展示「解析」入口。
func ShouldShowParseUI(r model.Result, flags []string, parses []model.Parse) bool {
	return IsUseParse(r, flags, parses)
}

// EpisodeURL 对齐 TV ParseJob：webUrl = result.getUrl().v()（不含 playUrl 前缀）。
func EpisodeURL(r model.Result) string {
	if len(r.URL.URLs) > 0 {
		return r.URL.URLs[0]
	}
	return ""
}

// WebURL 兼容旧调用：playUrl 前缀 + url（仅在明确需要拼前缀时使用）。
func WebURL(r model.Result) string {
	return r.PlayURL + EpisodeURL(r)
}

// ResolveWithParses 对非直链播放结果执行二次解析。
func ResolveWithParses(r model.Result, opts Options) (model.Result, error) {
	parses := opts.Parses
	flags := opts.Flags
	useParse := IsUseParse(r, flags, parses)
	need := NeedParse(r)
	if !need && !useParse {
		parseLog("[parse] skip need=%v useParse=%v flag=%q playUrl=%s url=%s",
			need, useParse, r.Flag, parsePreview(r.PlayURL, 80), parsePreview(EpisodeURL(r), 120))
		return r, nil
	}

	start := time.Now()
	// 对齐 TV：doInBackground 的 webUrl 始终是 episode URL，json:/parse: 只改 selected parse。
	hdr := mergeHeaders(nil, map[string]string(r.Header))
	webURL := EpisodeURL(r)
	// 相对播放页：用结果头 Referer 拼绝对地址，避免 unsupported protocol scheme。
	if webURL != "" && !strings.Contains(webURL, "://") {
		ref := ""
		for _, k := range []string{"Referer", "referer", "Origin", "origin"} {
			if v := strings.TrimSpace(hdr[k]); strings.HasPrefix(v, "http") {
				ref = v
				break
			}
		}
		if ref != "" {
			if abs := util.ResolveRelativeURL(ref, webURL); abs != "" && abs != webURL {
				parseLog("[parse] resolve relative web %s + %s → %s", ref, webURL, abs)
				webURL = abs
				if len(r.URL.URLs) > 0 {
					r.URL.URLs[0] = abs
				} else {
					r.URL = model.URL{URLs: []string{abs}}
				}
			}
		}
	}
	parseLog("[parse] start need=%v useParse=%v flag=%q prefer=%q click=%q web=%s playUrl=%s parses=%d",
		need, useParse, firstNonEmpty(opts.Flag, r.Flag), opts.Prefer,
		firstNonEmpty(opts.SiteClick, opts.Click, r.Click),
		parsePreview(webURL, 160), parsePreview(r.PlayURL, 80), len(parses))
	if webURL == "" {
		parseLog("[parse] fail: 无可解析地址")
		return r, fmt.Errorf("无可解析地址")
	}
	if matchVideo(webURL, opts.Rules, opts.IsVideo) {
		parseLog("[parse] already video web=%s cost=%s", parsePreview(webURL, 160), time.Since(start).Truncate(time.Millisecond))
		r.Parse = model.FlexInt{Valid: true, Value: 0}
		return r, nil
	}
	// 爬虫自带 playUrl 前缀且拼起来已是直链时，直接放行。
	if full := strings.TrimSpace(r.PlayURL) + webURL; r.PlayURL != "" &&
		!strings.HasPrefix(r.PlayURL, "json:") && !strings.HasPrefix(r.PlayURL, "parse:") &&
		matchVideo(full, opts.Rules, opts.IsVideo) {
		parseLog("[parse] playUrl+web already video full=%s cost=%s", parsePreview(full, 160), time.Since(start).Truncate(time.Millisecond))
		r.Parse = model.FlexInt{Valid: true, Value: 0}
		r.URL = model.URL{URLs: []string{full}}
		r.PlayURL = ""
		return r, nil
	}

	flag := opts.Flag
	if flag == "" {
		flag = r.Flag
	}
	click := strings.TrimSpace(opts.SiteClick)
	if click == "" {
		click = opts.Click
	}
	if click == "" {
		click = r.Click
	}

	p := resolveParse(r, parses, useParse, opts.Prefer)
	var parsed string
	var sniffHdr map[string]string
	var err error
	var via string
	if p != nil {
		parseLog("[parse] selected name=%q type=%d url=%s", p.Name, p.TypeID(), parsePreview(p.URL, 120))
		parsed, sniffHdr, err = executeParse(*p, webURL, flag, hdr, parses, opts.Rules, click, opts.IsVideo)
		if parsed != "" && err == nil {
			via = fmt.Sprintf("parse:%s/type%d", p.Name, p.TypeID())
		} else {
			parseLog("[parse] selected fail name=%q err=%v", p.Name, err)
		}
	} else {
		parseLog("[parse] no selected parse (useParse=%v prefer=%q)", useParse, opts.Prefer)
	}
	if parsed == "" || err != nil {
		for _, cand := range parses {
			if cand.TypeID() != 1 || cand.URL == "" {
				continue
			}
			if p != nil && cand.Name == p.Name {
				continue
			}
			var h map[string]string
			t0 := time.Now()
			parsed, h, err = JSONParseEx(cand.URL, webURL, mergeHeaders(hdr, parseExtHeaders(cand.Ext.String())))
			sniffHdr = h
			if err == nil && parsed != "" {
				via = fmt.Sprintf("json-fallback:%s", cand.Name)
				parseLog("[parse] json fallback ok name=%q out=%s cost=%s", cand.Name, parsePreview(parsed, 160), time.Since(t0).Truncate(time.Millisecond))
				break
			}
			parseLog("[parse] json fallback fail name=%q err=%v cost=%s", cand.Name, err, time.Since(t0).Truncate(time.Millisecond))
		}
	}
	if parsed == "" {
		t0 := time.Now()
		if sniffed, e := PlayPageSniff(webURL, hdr); e == nil && sniffed != "" {
			parsed = sniffed
			sniffHdr = nil
			via = "http-sniff"
			parseLog("[parse] PlayPageSniff ok out=%s cost=%s", parsePreview(parsed, 160), time.Since(t0).Truncate(time.Millisecond))
		} else if e != nil {
			parseLog("[parse] PlayPageSniff fail err=%v cost=%s", e, time.Since(t0).Truncate(time.Millisecond))
		}
	}
	if parsed == "" {
		t0 := time.Now()
		sniffURL := webURL
		if cloud := ResolveCloudPlayerPage(webURL, hdr); cloud != "" && cloud != webURL {
			parseLog("[parse] cloud-player %s", parsePreview(cloud, 160))
			if matchVideo(cloud, opts.Rules, opts.IsVideo) {
				parsed, sniffHdr, err = cloud, nil, nil
				via = "cloud-player"
			} else {
				sniffURL = cloud
			}
		}
		if parsed == "" {
			if u, h, e := browserSniff(sniffURL, hdr, click, opts.Rules, defaultParseWebTimeout, true, opts.IsVideo, 0); e == nil && u != "" {
				parsed, sniffHdr, err = u, h, nil
				via = "browser-sniff"
				parseLog("[parse] browserSniff ok out=%s cost=%s", parsePreview(parsed, 160), time.Since(t0).Truncate(time.Millisecond))
			} else {
				if sniffURL != webURL {
					parseLog("[parse] cloud sniff fail, fallback shell err=%v", e)
					if u, h, e2 := browserSniff(webURL, hdr, click, opts.Rules, defaultParseWebTimeout, true, opts.IsVideo, 0); e2 == nil && u != "" {
						parsed, sniffHdr, err = u, h, nil
						via = "browser-sniff"
						parseLog("[parse] browserSniff ok out=%s cost=%s", parsePreview(parsed, 160), time.Since(t0).Truncate(time.Millisecond))
					} else {
						err = e2
						if err == nil {
							err = e
						}
						parseLog("[parse] browserSniff fail err=%v cost=%s", err, time.Since(t0).Truncate(time.Millisecond))
					}
				} else {
					err = e
					parseLog("[parse] browserSniff fail err=%v cost=%s", e, time.Since(t0).Truncate(time.Millisecond))
				}
			}
		}
	}
	if parsed == "" {
		parseLog("[parse] fail final err=%v cost=%s", err, time.Since(start).Truncate(time.Millisecond))
		if err != nil {
			return r, AnnotateParseErr(err)
		}
		return r, fmt.Errorf("解析失败: 无可用解析器")
	}
	// 过短结果不可信；明显网页地址也不当媒体。
	if !matchVideo(parsed, opts.Rules, opts.IsVideo) {
		if len(parsed) <= 40 || looksLikeHTMLPlayPage(parsed) {
			parseLog("[parse] invalid result via=%s out=%s", via, parsePreview(parsed, 160))
			return r, fmt.Errorf("解析结果无效")
		}
	}

	parseLog("[parse] ok via=%s out=%s cost=%s", via, parsePreview(parsed, 200), time.Since(start).Truncate(time.Millisecond))
	r.Parse = model.FlexInt{Valid: true, Value: 0}
	r.URL = model.URL{URLs: []string{parsed}}
	r.PlayURL = ""
	if len(sniffHdr) > 0 {
		r.Header = model.FlexHeader(mergeHeaders(map[string]string(r.Header), pickPlayHeaders(sniffHdr)))
	}
	return r, nil
}

func firstNonEmpty(ss ...string) string {
	for _, s := range ss {
		if strings.TrimSpace(s) != "" {
			return strings.TrimSpace(s)
		}
	}
	return ""
}

func looksLikeHTMLPlayPage(u string) bool {
	lower := strings.ToLower(strings.TrimSpace(u))
	if i := strings.IndexByte(lower, '?'); i >= 0 {
		lower = lower[:i]
	}
	if strings.HasSuffix(lower, ".html") || strings.HasSuffix(lower, ".htm") {
		return true
	}
	return strings.Contains(lower, "/vod/play/") || strings.Contains(lower, "/index.php/vod/")
}

// matchVideo 优先走站点 isVideo（对齐 TV CustomWebView），否则走规则嗅探。
func matchVideo(u string, rules []model.Rule, check func(string) bool) bool {
	if check != nil {
		return check(u)
	}
	return IsVideoFormatRules(u, rules)
}

// ResolveLiveURL 直播地址解析。
func ResolveLiveURL(raw string, needParse bool, parses []model.Parse, headers map[string]string) (string, error) {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return "", nil
	}
	if strings.HasPrefix(raw, "json:") {
		u := strings.TrimPrefix(raw, "json:")
		if IsVideoFormat(u) {
			return u, nil
		}
		out, err := JSONParse(u, "", headers)
		if out != "" {
			return out, err
		}
		return PlayPageSniff(u, headers)
	}
	if strings.HasPrefix(raw, "parse:") {
		name := strings.TrimPrefix(raw, "parse:")
		for _, p := range parses {
			if p.Name == name {
				u, _, err := executeParse(p, "", "", headers, parses, nil, "", nil)
				return u, err
			}
		}
	}
	if IsVideoFormat(raw) {
		return raw, nil
	}
	if !needParse && !strings.HasPrefix(raw, "http") {
		return raw, nil
	}

	for _, p := range parses {
		if p.TypeID() != 1 || p.URL == "" {
			continue
		}
		out, err := JSONParse(p.URL, raw, headers)
		if err == nil && out != "" {
			return out, nil
		}
	}
	if needParse {
		if sniffed, _ := PlayPageSniff(raw, headers); sniffed != "" {
			return sniffed, nil
		}
		return "", fmt.Errorf("直播地址需要解析但无可用解析器")
	}
	return raw, nil
}

func resolveParse(r model.Result, parses []model.Parse, useParse bool, prefer string) *model.Parse {
	// 选用全局解析器；json:/parse: 前缀可覆盖。
	var selected *model.Parse
	if useParse {
		if prefer != "" {
			for i := range parses {
				if parses[i].Name == prefer {
					selected = &parses[i]
					break
				}
			}
		}
		if selected == nil && len(parses) > 0 {
			selected = &parses[0]
		}
	}

	playURL := r.PlayURL
	switch {
	case strings.HasPrefix(playURL, "json:"):
		return &model.Parse{Name: "inline", Type: model.FlexInt{Valid: true, Value: 1}, URL: strings.TrimPrefix(playURL, "json:")}
	case strings.HasPrefix(playURL, "parse:"):
		name := strings.TrimPrefix(playURL, "parse:")
		for i := range parses {
			if parses[i].Name == name {
				return &parses[i]
			}
		}
	}

	if selected != nil && !selectedEmpty(selected) {
		return selected
	}
	// 对齐 TV ParseJob.setParse：parse 为空 → Parse.get(0, playUrl)（可为无前缀，直接嗅探 episode）。
	return &model.Parse{Name: "inline", Type: model.FlexInt{Valid: true, Value: 0}, URL: playURL}
}

func selectedEmpty(p *model.Parse) bool {
	if p == nil {
		return true
	}
	return strings.TrimSpace(p.Name) == "" && strings.TrimSpace(p.URL) == ""
}

func executeParse(p model.Parse, webURL, flag string, headers map[string]string, parses []model.Parse, rules []model.Rule, click string, isVideo func(string) bool) (string, map[string]string, error) {
	headers = mergeHeaders(headers, parseExtHeaders(p.Ext.String()))
	start := time.Now()
	parseLog("[parse] execute name=%q type=%d web=%s", p.Name, p.TypeID(), parsePreview(webURL, 120))
	switch p.TypeID() {
	case 1:
		u, h, err := JSONParseEx(p.URL, webURL, headers)
		if err != nil {
			parseLog("[parse] type1 fail name=%q err=%v cost=%s", p.Name, err, time.Since(start).Truncate(time.Millisecond))
			return "", nil, err
		}
		// 对齐 TV checkResult fatal：url.length() > 40
		if u != "" && len(u) <= 40 {
			parseLog("[parse] type1 too-short name=%q out=%q", p.Name, u)
			return "", nil, fmt.Errorf("json 解析结果过短")
		}
		parseLog("[parse] type1 ok name=%q out=%s cost=%s", p.Name, parsePreview(u, 160), time.Since(start).Truncate(time.Millisecond))
		return u, pickPlayHeaders(h), nil
	case 0:
		// 对齐 TV startWeb(key, parse, webUrl)：parse.getUrl() + webUrl
		target := strings.TrimSpace(p.URL) + webURL
		if target == "" {
			return "", nil, fmt.Errorf("无可嗅探地址")
		}
		parseLog("[parse] type0 target=%s", parsePreview(target, 160))
		if out, err := PlayPageSniff(target, headers); err == nil && out != "" {
			parseLog("[parse] type0 http-sniff ok out=%s cost=%s", parsePreview(out, 160), time.Since(start).Truncate(time.Millisecond))
			return out, nil, nil
		}
		// 站点壳页常有登录墙/广告脚本；先解析 MacPlayer 云播地址再嗅探（对齐 JS lazy 拼 jsh）。
		sniffTarget := target
		if cloud := ResolveCloudPlayerPage(target, headers); cloud != "" && cloud != target {
			parseLog("[parse] type0 cloud-player %s", parsePreview(cloud, 160))
			if matchVideo(cloud, rules, isVideo) {
				return cloud, nil, nil
			}
			sniffTarget = cloud
		}
		u, h, err := browserSniff(sniffTarget, headers, click, rules, defaultParseWebTimeout, true, isVideo, 0)
		if err != nil && sniffTarget != target {
			parseLog("[parse] type0 cloud sniff fail, fallback shell err=%v", err)
			u, h, err = browserSniff(target, headers, click, rules, defaultParseWebTimeout, true, isVideo, 0)
		}
		if err != nil {
			parseLog("[parse] type0 browser fail err=%v cost=%s", err, time.Since(start).Truncate(time.Millisecond))
		} else {
			parseLog("[parse] type0 browser ok out=%s cost=%s", parsePreview(u, 160), time.Since(start).Truncate(time.Millisecond))
		}
		return u, h, err
	case 2:
		u, h, needWeb, err := jarJSONExt(p, webURL, parses)
		if err != nil {
			parseLog("[parse] type2 fail name=%q err=%v cost=%s", p.Name, err, time.Since(start).Truncate(time.Millisecond))
			return "", nil, err
		}
		parseLog("[parse] type2 ok name=%q needWeb=%v out=%s cost=%s", p.Name, needWeb, parsePreview(u, 160), time.Since(start).Truncate(time.Millisecond))
		if needWeb {
			return sniffParsedWeb(u, mergeHeaders(headers, h), click, rules, isVideo)
		}
		return u, pickPlayHeaders(h), nil
	case 3:
		u, h, needWeb, err := jarJSONExtMix(p, flag, webURL, parses)
		if err != nil {
			parseLog("[parse] type3 fail name=%q err=%v cost=%s", p.Name, err, time.Since(start).Truncate(time.Millisecond))
			return "", nil, err
		}
		parseLog("[parse] type3 ok name=%q needWeb=%v out=%s cost=%s", p.Name, needWeb, parsePreview(u, 160), time.Since(start).Truncate(time.Millisecond))
		if needWeb {
			return sniffParsedWeb(u, mergeHeaders(headers, h), click, rules, isVideo)
		}
		return u, pickPlayHeaders(h), nil
	case 4:
		// 对齐 TV ParseJob.superParse：type1（按 flag 筛）竞速 + type0 Web 嗅探。
		parseLog("[parse] type4 superParse flag=%q", flag)
		return superParse(webURL, flag, headers, parses, rules, click, isVideo)
	default:
		return "", nil, fmt.Errorf("未知解析类型: %d", p.TypeID())
	}
}

// sniffParsedWeb 对齐 TV checkResult：jar 返回 needParse 时再走 Web 嗅探。
func sniffParsedWeb(pageURL string, headers map[string]string, click string, rules []model.Rule, isVideo func(string) bool) (string, map[string]string, error) {
	pageURL = strings.TrimSpace(pageURL)
	if pageURL == "" {
		return "", nil, fmt.Errorf("jar 解析需二次嗅探但无地址")
	}
	if out, err := PlayPageSniff(pageURL, headers); err == nil && out != "" {
		return out, nil, nil
	}
	return browserSniff(pageURL, headers, click, rules, defaultParseWebTimeout, true, isVideo, 0)
}

// superParse 对齐 TV ParseJob.superParse / getParses(type, flag)。
func superParse(webURL, flag string, headers map[string]string, parses []model.Parse, rules []model.Rule, click string, isVideo func(string) bool) (string, map[string]string, error) {
	jsons := getParses(parses, 1, flag)
	webs := getParses(parses, 0, flag)
	parseLog("[parse] superParse flag=%q json=%d web=%d", flag, len(jsons), len(webs))
	type result struct {
		url string
		hdr map[string]string
	}
	n := len(jsons)
	if len(webs) > 0 {
		n++
	}
	if n == 0 {
		return "", nil, fmt.Errorf("超级解析无可用解析器")
	}
	ch := make(chan result, n)
	var wg sync.WaitGroup
	for _, item := range jsons {
		wg.Add(1)
		go func(p model.Parse) {
			defer wg.Done()
			hdr := mergeHeaders(headers, parseExtHeaders(p.Ext.String()))
			u, h, err := JSONParseEx(p.URL, webURL, hdr)
			// 对齐 TV checkResult：url.length() > 40 才算成功。
			if err == nil && len(u) > 40 {
				ch <- result{url: u, hdr: pickPlayHeaders(h)}
			}
		}(item)
	}
	if len(webs) > 0 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			// 对齐 TV：单页 /parse?jxs=… 聚合 iframe 竞速，只开一次 Chromium tab。
			var sb strings.Builder
			for _, item := range webs {
				sb.WriteString(strings.TrimSpace(item.URL))
				sb.WriteByte(';')
			}
			jxs := strings.TrimSuffix(sb.String(), ";")
			if jxs != "" {
				parsePage := fmt.Sprintf("http://127.0.0.1:%d/parse?jxs=%s&url=%s",
					localproxy.Port(), url.QueryEscape(jxs), url.QueryEscape(webURL))
				if out, err := PlayPageSniff(parsePage, headers); err == nil && out != "" && matchVideo(out, rules, isVideo) {
					ch <- result{url: out}
					return
				}
				if u, h, err := browserSniff(parsePage, headers, click, rules, defaultParseWebTimeout, true, isVideo, 0); err == nil && u != "" {
					ch <- result{url: u, hdr: h}
					return
				}
			}
			// 回落：顺序嗅探各 type0（共享 Chromium，不再并行开进程）
			for _, item := range webs {
				target := strings.TrimSpace(item.URL) + webURL
				if target == "" {
					continue
				}
				hdr := mergeHeaders(headers, parseExtHeaders(item.Ext.String()))
				if out, err := PlayPageSniff(target, hdr); err == nil && out != "" && matchVideo(out, rules, isVideo) {
					ch <- result{url: out}
					return
				}
				if u, h, err := browserSniff(target, hdr, click, rules, defaultParseWebTimeout, true, isVideo, 0); err == nil && u != "" {
					ch <- result{url: u, hdr: h}
					return
				}
			}
			if u, h, err := browserSniff(webURL, headers, click, rules, defaultParseWebTimeout, true, isVideo, 0); err == nil && u != "" {
				ch <- result{url: u, hdr: h}
			}
		}()
	}
	go func() {
		wg.Wait()
		close(ch)
	}()
	for r := range ch {
		if r.url != "" {
			return r.url, r.hdr, nil
		}
	}
	return "", nil, fmt.Errorf("超级解析失败")
}

// getParses 对齐 TV VodConfig.getParses(type) / getParses(type, flag)。
func getParses(parses []model.Parse, typ int, flag string) []model.Parse {
	var items []model.Parse
	for _, p := range parses {
		if p.TypeID() == typ {
			items = append(items, p)
		}
	}
	flag = strings.TrimSpace(flag)
	if flag == "" {
		return items
	}
	var filtered []model.Parse
	for _, p := range items {
		for _, f := range parseExtFlags(p.Ext.String()) {
			if f == flag {
				filtered = append(filtered, p)
				break
			}
		}
	}
	if len(filtered) == 0 {
		return items
	}
	return filtered
}

func parseExtFlags(ext string) []string {
	ext = strings.TrimSpace(ext)
	if ext == "" || ext == "{}" || ext == "null" {
		return nil
	}
	var obj struct {
		Flag []string `json:"flag"`
	}
	if json.Unmarshal([]byte(ext), &obj) != nil {
		return nil
	}
	return obj.Flag
}

func parseExtHeaders(ext string) map[string]string {
	ext = strings.TrimSpace(ext)
	if ext == "" || ext == "{}" || ext == "null" {
		return nil
	}
	var obj struct {
		Header map[string]string `json:"header"`
	}
	if json.Unmarshal([]byte(ext), &obj) != nil || len(obj.Header) == 0 {
		return nil
	}
	return obj.Header
}

func parseExtEmpty(ext string) bool {
	ext = strings.TrimSpace(ext)
	if ext == "" || ext == "{}" || ext == "null" {
		return true
	}
	var obj struct {
		Flag   []string          `json:"flag"`
		Header map[string]string `json:"header"`
	}
	if json.Unmarshal([]byte(ext), &obj) != nil {
		return true
	}
	return len(obj.Flag) == 0 && len(obj.Header) == 0
}

// parseExtURL 对齐 TV Parse.extUrl：在 ? 后插入 cat_ext=base64url(ext)。
func parseExtURL(p model.Parse) string {
	u := p.URL
	ext := p.Ext.String()
	if parseExtEmpty(ext) {
		return u
	}
	index := strings.Index(u, "?")
	if index == -1 {
		return u
	}
	b64 := base64.URLEncoding.EncodeToString([]byte(ext))
	return u[:index+1] + "cat_ext=" + b64 + "&" + u[index+1:]
}

// pickPlayHeaders 保留对起播有用的请求头。
func pickPlayHeaders(h map[string]string) map[string]string {
	if len(h) == 0 {
		return nil
	}
	out := make(map[string]string)
	for k, v := range h {
		switch {
		case strings.EqualFold(k, "User-Agent"),
			strings.EqualFold(k, "Referer"),
			strings.EqualFold(k, "Origin"),
			strings.EqualFold(k, "Cookie"),
			strings.EqualFold(k, "Authorization"):
			if strings.TrimSpace(v) != "" {
				out[k] = v
			}
		}
	}
	return out
}

func jarJSONExt(p model.Parse, webURL string, parses []model.Parse) (string, map[string]string, bool, error) {
	jxs := map[string]string{}
	for _, cand := range parses {
		if cand.TypeID() == 1 && cand.URL != "" {
			// 对齐 TV ParseJob.jsonExtend：jxs 用 item.extUrl()
			jxs[cand.Name] = parseExtURL(cand)
		}
	}
	raw, err := spider.JsonExt(strings.TrimSpace(p.URL), jxs, webURL)
	if err != nil {
		return "", nil, false, err
	}
	return extractPlayFromJSON(raw)
}

func jarJSONExtMix(p model.Parse, flag, webURL string, parses []model.Parse) (string, map[string]string, bool, error) {
	jxs := map[string]map[string]string{}
	for _, cand := range parses {
		jxs[cand.Name] = map[string]string{
			"type": fmt.Sprintf("%d", cand.TypeID()),
			"url":  cand.URL,
			"ext":  cand.Ext.String(),
		}
	}
	// 对齐 TV ParseJob.jsonMix：key = parse.getUrl()（如 Web → MixWeb）
	raw, err := spider.JsonExtMix(flag, strings.TrimSpace(p.URL), p.Name, jxs, webURL)
	if err != nil {
		return "", nil, false, err
	}
	return extractPlayFromJSON(raw)
}

// extractPlayFromJSON 对齐 TV checkResult(Result)：抽 url/header，needParse 时需二次 Web。
func extractPlayFromJSON(raw string) (string, map[string]string, bool, error) {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return "", nil, false, nil
	}
	var r model.Result
	if err := json.Unmarshal([]byte(raw), &r); err == nil {
		u := EpisodeURL(r)
		if u == "" {
			// 兼容少数 jar 只写 playUrl
			u = strings.TrimSpace(r.PlayURL)
		}
		hdr := map[string]string(r.Header)
		if u != "" {
			return u, hdr, NeedParse(r), nil
		}
	}
	u, hdr := parseJSONPlayBody(raw)
	if u != "" {
		return u, hdr, false, nil
	}
	if IsVideoFormat(raw) {
		return raw, nil, false, nil
	}
	if sniffed := ExtractMediaURL(raw); sniffed != "" {
		return sniffed, nil, false, nil
	}
	return "", nil, false, nil
}

func mergeHeaders(a, b map[string]string) map[string]string {
	out := make(map[string]string)
	for k, v := range a {
		out[k] = v
	}
	for k, v := range b {
		out[k] = v
	}
	return out
}

var (
	dataPlayRe   = regexp.MustCompile(`(?i)data-play\s*=\s*["']([^"']+)["']`)
	playerConfRe = regexp.MustCompile(`(?is)player_[a-zA-Z0-9_]*\s*=\s*(\{.*?\})\s*<`)
	urlFieldRe   = regexp.MustCompile(`"url"\s*:\s*"([^"]+)"`)
	encryptRe    = regexp.MustCompile(`"encrypt"\s*:\s*(\d+)`)
)

// PlayPageSniff 播放页嗅探。
func PlayPageSniff(pageURL string, headers map[string]string) (string, error) {
	if pageURL == "" {
		return "", nil
	}
	if IsVideoFormat(pageURL) {
		return pageURL, nil
	}
	start := time.Now()
	hdr := mergeHeaders(map[string]string{
		"User-Agent": "Mozilla/5.0 (Linux; Android 11) AppleWebKit/537.36 Chrome/90.0.4430.91 Mobile Safari/537.36",
		"Referer":    pageURL,
	}, headers)
	body, err := util.HTTPGet(pageURL, hdr)
	if err != nil {
		parseLog("[http-sniff] get fail url=%s err=%v cost=%s", parsePreview(pageURL, 120), err, time.Since(start).Truncate(time.Millisecond))
		return "", err
	}
	if m := dataPlayRe.FindStringSubmatch(body); len(m) > 1 {
		if u := decodeDataPlay(m[1]); u != "" {
			parseLog("[http-sniff] data-play ok url=%s out=%s cost=%s", parsePreview(pageURL, 100), parsePreview(u, 120), time.Since(start).Truncate(time.Millisecond))
			return u, nil
		}
		if IsVideoFormat(m[1]) {
			return m[1], nil
		}
	}
	if m := playerConfRe.FindStringSubmatch(body); len(m) > 1 {
		if u := extractPlayerConfURL(m[1]); u != "" {
			parseLog("[http-sniff] player conf ok url=%s out=%s cost=%s", parsePreview(pageURL, 100), parsePreview(u, 120), time.Since(start).Truncate(time.Millisecond))
			return u, nil
		}
	}
	out := ExtractMediaURL(body)
	if out != "" {
		parseLog("[http-sniff] extract ok url=%s out=%s cost=%s", parsePreview(pageURL, 100), parsePreview(out, 120), time.Since(start).Truncate(time.Millisecond))
	} else {
		parseLog("[http-sniff] miss url=%s body=%d cost=%s", parsePreview(pageURL, 100), len(body), time.Since(start).Truncate(time.Millisecond))
	}
	return out, nil
}

func decodeDataPlay(raw string) string {
	maxPrefix := 12
	if len(raw)-4 < maxPrefix {
		maxPrefix = len(raw) - 4
		if maxPrefix < 0 {
			maxPrefix = 0
		}
	}
	for prefixLen := 0; prefixLen <= maxPrefix; prefixLen++ {
		part := raw
		if prefixLen > 0 {
			part = raw[prefixLen:]
		}
		b, err := base64.StdEncoding.DecodeString(padBase64(part))
		if err != nil {
			continue
		}
		decoded := string(b)
		idx := strings.Index(decoded, "http")
		if idx < 0 {
			continue
		}
		clean := decoded[idx:]
		clean = strings.Split(clean, " ")[0]
		clean = strings.Split(clean, "\n")[0]
		clean = strings.TrimSpace(clean)
		if IsVideoFormat(clean) {
			return clean
		}
	}
	return ""
}

func extractPlayerConfURL(jsonBlob string) string {
	um := urlFieldRe.FindStringSubmatch(jsonBlob)
	if len(um) < 2 {
		return ""
	}
	result := um[1]
	em := encryptRe.FindStringSubmatch(jsonBlob)
	if len(em) > 1 {
		switch em[1] {
		case "1":
			if d, err := url.QueryUnescape(result); err == nil {
				result = d
			}
		case "2":
			if b, err := base64.StdEncoding.DecodeString(padBase64(result)); err == nil {
				result = string(b)
				if d, err := url.QueryUnescape(result); err == nil {
					result = d
				}
			}
		}
	}
	if IsVideoFormat(result) {
		return result
	}
	return ""
}

var (
	playerFromRe   = regexp.MustCompile(`"from"\s*:\s*"([^"]+)"`)
	playerSrcAssignRe = regexp.MustCompile(`(?is)\.src\s*=\s*(.+?);`)
)

// ResolveCloudPlayerPage 从 CMS 播放页抽出 MacPlayer 云播页（yunbox/404.php 等）。
// 站点壳常有 Win/Mac 登录墙或非桌面广告劫持；直接嗅探云播页更稳。
func ResolveCloudPlayerPage(pageURL string, headers map[string]string) string {
	pageURL = strings.TrimSpace(pageURL)
	if pageURL == "" || !strings.HasPrefix(strings.ToLower(pageURL), "http") {
		return ""
	}
	hdr := mergeHeaders(map[string]string{
		"User-Agent": sniffUAMobile,
		"Referer":    pageURL,
	}, headers)
	body, err := util.HTTPGet(pageURL, hdr)
	if err != nil || body == "" {
		return ""
	}
	m := playerConfRe.FindStringSubmatch(body)
	if len(m) < 2 {
		return ""
	}
	blob := m[1]
	if u := extractPlayerConfURL(blob); u != "" {
		return u
	}
	var conf struct {
		URL     string `json:"url"`
		From    string `json:"from"`
		Encrypt int    `json:"encrypt"`
	}
	if err := json.Unmarshal([]byte(blob), &conf); err != nil {
		// 正则截到的 blob 偶发缺引号转义，再走字段正则兜底。
		playURL := ""
		if um := urlFieldRe.FindStringSubmatch(blob); len(um) > 1 {
			playURL = strings.ReplaceAll(um[1], `\/`, "/")
		}
		fm := playerFromRe.FindStringSubmatch(blob)
		if playURL == "" || len(fm) < 2 {
			return ""
		}
		conf.URL, conf.From = playURL, fm[1]
		if em := encryptRe.FindStringSubmatch(blob); len(em) > 1 {
			fmt.Sscanf(em[1], "%d", &conf.Encrypt)
		}
	}
	playURL := conf.URL
	switch conf.Encrypt {
	case 1:
		if d, err := url.QueryUnescape(playURL); err == nil {
			playURL = d
		}
	case 2:
		if b, err := base64.StdEncoding.DecodeString(padBase64(playURL)); err == nil {
			playURL = string(b)
			if d, err := url.QueryUnescape(playURL); err == nil {
				playURL = d
			}
		}
	}
	playURL = strings.ReplaceAll(playURL, `\/`, "/")
	from := strings.TrimSpace(conf.From)
	if playURL == "" || from == "" {
		return ""
	}
	base, err := url.Parse(pageURL)
	if err != nil || base.Scheme == "" || base.Host == "" {
		return ""
	}
	playerJS := base.Scheme + "://" + base.Host + "/static/player/" + from + ".js"
	jsBody, err := util.HTTPGet(playerJS, mergeHeaders(hdr, map[string]string{"Referer": pageURL}))
	if err != nil {
		return ""
	}
	sm := playerSrcAssignRe.FindStringSubmatch(jsBody)
	if len(sm) < 2 {
		return ""
	}
	tpl := sm[1]
	jsh := buildMacPlayerSrc(tpl, playURL, pageURL)
	if jsh == "" || !strings.HasPrefix(strings.ToLower(jsh), "http") {
		return ""
	}
	// 无 type= 的入口常 302；跟一层 Location。
	if !strings.Contains(jsh, "type=") {
		if loc := httpRedirectLocation(jsh, hdr); loc != "" {
			jsh = loc
		}
	}
	return jsh
}

func buildMacPlayerSrc(tpl, playURL, pageURL string) string {
	s := tpl
	s = strings.ReplaceAll(s, "+", "")
	s = strings.ReplaceAll(s, " ", "")
	s = strings.ReplaceAll(s, "'", "")
	s = strings.ReplaceAll(s, "MacPlayer.Parse", "")
	s = strings.ReplaceAll(s, "MacPlayer.PlayUrl", playURL)
	s = strings.ReplaceAll(s, "window.location.href", pageURL)
	return strings.TrimSpace(s)
}

func httpRedirectLocation(raw string, headers map[string]string) string {
	req, err := http.NewRequest(http.MethodGet, util.EncodeURL(raw), nil)
	if err != nil {
		return ""
	}
	if headers == nil || headers["User-Agent"] == "" {
		req.Header.Set("User-Agent", sniffUAMobile)
	}
	for k, v := range headers {
		req.Header.Set(k, v)
	}
	client := &http.Client{
		Timeout: 15 * time.Second,
		CheckRedirect: func(req *http.Request, via []*http.Request) error {
			return http.ErrUseLastResponse
		},
	}
	resp, err := client.Do(req)
	if err != nil || resp == nil {
		return ""
	}
	defer resp.Body.Close()
	loc := strings.TrimSpace(resp.Header.Get("Location"))
	if loc == "" {
		return ""
	}
	if strings.HasPrefix(loc, "/") {
		if u, err := url.Parse(raw); err == nil {
			loc = u.Scheme + "://" + u.Host + loc
		}
	}
	return strings.ReplaceAll(loc, " ", "+")
}

func padBase64(s string) string {
	pad := (4 - len(s)%4) % 4
	return s + strings.Repeat("=", pad)
}
