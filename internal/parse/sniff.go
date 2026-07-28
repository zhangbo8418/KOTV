package parse

import (
	"regexp"
	"strings"
)

var mediaURLRe = regexp.MustCompile(`(?i)https?://[^\s"'<>\\]+?\.(?:m3u8|mp4|mkv|flv|ts|mpd)(?:\?[^\s"'<>\\]*)?`)

// HTTPSniff 从 HTML/文本页面中嗅探媒体地址（委托 PlayPageSniff）。
func HTTPSniff(pageURL string, headers map[string]string) (string, error) {
	return PlayPageSniff(pageURL, headers)
}

// ExtractMediaURL 从文本中提取第一个看起来像视频的 URL。
func ExtractMediaURL(body string) string {
	matches := mediaURLRe.FindAllString(body, -1)
	for _, m := range matches {
		m = strings.TrimRight(m, `",');>]`)
		if IsVideoFormat(m) {
			return m
		}
	}
	idx := strings.Index(strings.ToLower(body), `"url"`)
	if idx >= 0 {
		rest := body[idx:]
		if m := mediaURLRe.FindString(rest); m != "" {
			return strings.TrimRight(m, `",');>]`)
		}
	}
	return ""
}
