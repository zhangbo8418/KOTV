package parse

import (
	"strings"
)

// HTTPSniff 从 HTML/文本页面中嗅探媒体地址（委托 PlayPageSniff）。
func HTTPSniff(pageURL string, headers map[string]string) (string, error) {
	return PlayPageSniff(pageURL, headers)
}

// ExtractMediaURL 从文本中提取第一个看起来像视频的 URL（口径委托 IsVideoFormat / snifferRe）。
func ExtractMediaURL(body string) string {
	matches := snifferRe.FindAllString(body, -1)
	for _, m := range matches {
		m = strings.TrimRight(m, `",');>]`)
		if IsVideoFormat(m) {
			return m
		}
	}
	idx := strings.Index(strings.ToLower(body), `"url"`)
	if idx >= 0 {
		rest := body[idx:]
		if m := snifferRe.FindString(rest); m != "" {
			m = strings.TrimRight(m, `",');>]`)
			if IsVideoFormat(m) {
				return m
			}
		}
	}
	return ""
}
