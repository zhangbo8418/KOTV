package parse

import (
	"encoding/json"
	"fmt"
	"net/url"
	"regexp"
	"strings"

	"github.com/bobo/KOTV/internal/model"
	"github.com/bobo/KOTV/internal/util"
)

var (
	// 与常见嗅探规则一致：媒体扩展名 / 抖音系 video/tos / rtmp
	snifferRe = regexp.MustCompile(`(?i)https?://[^\s]{12,}\.(?:m3u8|mp4|mkv|flv|mp3|m4a|aac|mpd)(?:\?.*)?|https?://.*?video/tos[^\s]*|rtmp:[^\s]+`)
	// 内嵌播放器页：再跟进一层
	playerURLRe = regexp.MustCompile(`(?i)player.*https?://`)
	excludeHint = regexp.MustCompile(`(?i)(url=http|v=http|\.html|javascript:|about:blank)`)
)

// IsVideoFormat 判断是否为直链视频地址。
func IsVideoFormat(u string) bool {
	return IsVideoFormatRules(u, nil)
}

// IsVideoFormatRules 结合配置 rules 的 regex/exclude 判定媒体地址。
func IsVideoFormatRules(u string, rules []model.Rule) bool {
	u = strings.TrimSpace(u)
	if u == "" {
		return false
	}
	rule := matchRule(u, rules)
	for _, ex := range rule.Exclude {
		ex = strings.TrimSpace(ex)
		if ex == "" {
			continue
		}
		if strings.Contains(u, ex) {
			return false
		}
		if re, err := regexp.Compile(ex); err == nil && re.MatchString(u) {
			return false
		}
	}
	for _, rx := range rule.Regex {
		rx = strings.TrimSpace(rx)
		if rx == "" {
			continue
		}
		if strings.Contains(u, rx) {
			return true
		}
		if re, err := regexp.Compile(rx); err == nil && re.MatchString(u) {
			return true
		}
	}
	if excludeHint.MatchString(u) {
		return false
	}
	return snifferRe.MatchString(u)
}

func matchRule(raw string, rules []model.Rule) model.Rule {
	if len(rules) == 0 {
		return model.Rule{}
	}
	u, err := url.Parse(raw)
	if err != nil || u.Host == "" {
		return model.Rule{}
	}
	hosts := u.Hostname()
	if q := u.Query().Get("url"); q != "" {
		if qu, err := url.Parse(q); err == nil && qu.Hostname() != "" {
			hosts = hosts + "," + qu.Hostname()
		}
	}
	for _, rule := range rules {
		for _, h := range rule.Hosts {
			h = strings.TrimSpace(h)
			if h == "" {
				continue
			}
			if strings.Contains(strings.ToLower(hosts), strings.ToLower(h)) {
				return rule
			}
		}
	}
	return model.Rule{}
}

// JSONParse 使用解析器 URL + 网页地址获取直链（type=1）。
func JSONParse(parseURL, webURL string, headers map[string]string) (string, error) {
	u, _, err := JSONParseEx(parseURL, webURL, headers)
	return u, err
}

// JSONParseEx 对齐 TV ParseJob.jsonParse：取 url / data.url，并从 JSON 抽 UA/Referer/Cookie。
func JSONParseEx(parseURL, webURL string, headers map[string]string) (string, map[string]string, error) {
	if parseURL == "" {
		return "", nil, nil
	}
	full := parseURL
	if webURL != "" {
		full = parseURL + webURL
	}
	body, err := util.HTTPGet(full, headers)
	if err != nil {
		return "", nil, err
	}
	u, hdr := parseJSONPlayBody(body)
	if u != "" {
		return u, hdr, nil
	}
	trim := strings.TrimSpace(body)
	if IsVideoFormat(trim) {
		return trim, nil, nil
	}
	if sniffed := ExtractMediaURL(body); sniffed != "" {
		return sniffed, nil, nil
	}
	return "", nil, fmt.Errorf("json 解析无 url")
}

// parseJSONPlayBody 从 type1 / jar 返回的 JSON 抽播放地址与请求头。
func parseJSONPlayBody(body string) (string, map[string]string) {
	body = strings.TrimSpace(body)
	if body == "" {
		return "", nil
	}
	var obj map[string]json.RawMessage
	if json.Unmarshal([]byte(body), &obj) != nil {
		return "", nil
	}
	u := jsonStringField(obj, "url")
	if u == "" {
		if dataRaw, ok := obj["data"]; ok {
			var data map[string]json.RawMessage
			if json.Unmarshal(dataRaw, &data) == nil {
				u = jsonStringField(data, "url")
			}
		}
	}
	if u == "" {
		if arr := jsonStringArrayField(obj, "urls"); len(arr) > 0 {
			u = arr[0]
		}
	}
	hdr := map[string]string{}
	for k, raw := range obj {
		switch {
		case strings.EqualFold(k, "User-Agent"),
			strings.EqualFold(k, "ua"),
			strings.EqualFold(k, "Referer"),
			strings.EqualFold(k, "Cookie"):
			var s string
			if json.Unmarshal(raw, &s) == nil && strings.TrimSpace(s) != "" {
				key := k
				if strings.EqualFold(k, "ua") {
					key = "User-Agent"
				}
				hdr[key] = s
			}
		}
	}
	if len(hdr) == 0 {
		hdr = nil
	}
	return u, hdr
}

func jsonStringField(obj map[string]json.RawMessage, key string) string {
	raw, ok := obj[key]
	if !ok || raw == nil {
		return ""
	}
	var s string
	if json.Unmarshal(raw, &s) == nil {
		return strings.TrimSpace(s)
	}
	return ""
}

func jsonStringArrayField(obj map[string]json.RawMessage, key string) []string {
	raw, ok := obj[key]
	if !ok || raw == nil {
		return nil
	}
	var arr []string
	if json.Unmarshal(raw, &arr) == nil {
		return arr
	}
	return nil
}

// ResolvePlayURL 从 player 结果中提取可播放地址。
func ResolvePlayURL(raw string, playURL string, urls []string) string {
	for _, u := range urls {
		if u != "" {
			return u
		}
	}
	if playURL != "" {
		return playURL
	}
	if IsVideoFormat(raw) {
		return raw
	}
	return raw
}
