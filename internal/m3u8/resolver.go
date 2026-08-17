package m3u8

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"regexp"
	"strings"
	"sync"
	"time"

	"github.com/bobo/KOTV/internal/hostclient"
	"github.com/bobo/KOTV/internal/settings"
)

func jsonUnmarshal(raw string, v interface{}) error {
	return json.Unmarshal([]byte(raw), v)
}

var httpClient = &http.Client{Timeout: 20 * time.Second}

var headClient = &http.Client{Timeout: 4 * time.Second}

// ResolveForPlayback 下载并过滤 m3u8，返回可播放地址（本地代理或原 URL）。
func ResolveForPlayback(rawURL string, headers map[string]string, localPort int) (string, error) {
	if rawURL == "" || !strings.Contains(strings.ToLower(rawURL), "m3u8") {
		return rawURL, nil
	}
	if strings.Contains(rawURL, "/proxy/cached_m3u8") || strings.HasPrefix(rawURL, "file:") {
		return rawURL, nil
	}
	if !settings.IsAdFilterEnabled() {
		return rawURL, nil
	}

	content, err := fetch(rawURL, headers)
	if err != nil {
		return rawURL, nil // 失败时回退原地址
	}

	base := rawURL
	if IsMasterPlaylist(content) {
		variant := firstVariantURL(content, base)
		if variant == "" {
			return rawURL, nil
		}
		content, err = fetch(variant, headers)
		if err != nil {
			return rawURL, nil
		}
		base = variant
	}

	content = absolutizeURIs(content, base)
	content = absolutizeTagURIs(content, base)
	cfg := loadFilterConfig()

	var lms []time.Time
	if cfg.Mode == ModeSmart && cfg.UseLastModified && strings.Contains(content, "#EXT-X-DISCONTINUITY") {
		lms = sampleChunkLastModifieds(content, headers)
	}

	fil := NewFilter(cfg)
	filtered := fil.Apply(content, lms...)
	filtered = stripNonVideoSegments(filtered)
	filtered = convertRelativeTsToAbsolute(filtered, base)
	filtered = absolutizeTagURIs(filtered, base)

	segments := countSegments(filtered)
	if segments < 2 {
		return rawURL, nil
	}

	id := DefaultCache.Put(filtered)
	proxyBase := fmt.Sprintf("http://127.0.0.1:%d", localPort)
	if pb := hostclient.PublicBase(); pb != "" {
		proxyBase = strings.TrimRight(pb, "/")
	}
	return fmt.Sprintf("%s/proxy/cached_m3u8?id=%s", proxyBase, id), nil
}

func loadFilterConfig() FilterConfig {
	cfg := DefaultConfig()
	raw := settings.GetM3U8FilterConfigJSON()
	if raw == "" {
		return cfg
	}
	// 旧 ltxlong JSON：映射到新档位，丢弃序号启发式字段。
	if strings.Contains(raw, "violentFilterModeFlag") || strings.Contains(raw, "tsNameLenExtend") {
		if strings.Contains(raw, `"violentFilterModeFlag":true`) || strings.Contains(raw, `"violentFilterModeFlag": true`) {
			cfg.Mode = ModeMild
		} else {
			cfg.Mode = ModeSmart
		}
		return cfg
	}
	_ = jsonUnmarshal(raw, &cfg)
	return cfg.normalized()
}

func fetch(u string, headers map[string]string) (string, error) {
	req, err := http.NewRequest(http.MethodGet, u, nil)
	if err != nil {
		return "", err
	}
	for k, v := range headers {
		req.Header.Set(k, v)
	}
	if req.Header.Get("User-Agent") == "" {
		req.Header.Set("User-Agent", settings.PlayUA())
	}
	resp, err := httpClient.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	b, err := io.ReadAll(resp.Body)
	if err != nil {
		return "", err
	}
	return string(b), nil
}

// sampleChunkLastModifieds 对每个 DISCONTINUITY 段抽一个媒体 URI 做 HEAD，取 Last-Modified。
func sampleChunkLastModifieds(content string, headers map[string]string) []time.Time {
	parts := strings.Split(content, "#EXT-X-DISCONTINUITY")
	out := make([]time.Time, len(parts))
	var wg sync.WaitGroup
	for i, part := range parts {
		uri := firstMediaURI(part)
		if uri == "" {
			continue
		}
		wg.Add(1)
		go func(idx int, u string) {
			defer wg.Done()
			if t, ok := headLastModified(u, headers); ok {
				out[idx] = t
			}
		}(i, uri)
	}
	wg.Wait()
	return out
}

func firstMediaURI(chunk string) string {
	for _, line := range strings.Split(chunk, "\n") {
		trim := strings.TrimSpace(line)
		if trim == "" || strings.HasPrefix(trim, "#") {
			continue
		}
		low := strings.ToLower(trim)
		if strings.Contains(low, ".ts") ||
			strings.Contains(low, ".m4s") ||
			strings.Contains(low, ".mp4") ||
			strings.Contains(low, ".jpg") ||
			strings.Contains(low, ".jpeg") ||
			strings.Contains(low, ".png") {
			return trim
		}
	}
	return ""
}

func headLastModified(u string, headers map[string]string) (time.Time, bool) {
	do := func(method string) (time.Time, bool) {
		req, err := http.NewRequest(method, u, nil)
		if err != nil {
			return time.Time{}, false
		}
		for k, v := range headers {
			req.Header.Set(k, v)
		}
		if req.Header.Get("User-Agent") == "" {
			req.Header.Set("User-Agent", settings.PlayUA())
		}
		if method == http.MethodGet {
			req.Header.Set("Range", "bytes=0-0")
		}
		resp, err := headClient.Do(req)
		if err != nil {
			return time.Time{}, false
		}
		defer resp.Body.Close()
		_, _ = io.Copy(io.Discard, io.LimitReader(resp.Body, 64))
		if resp.StatusCode < 200 || resp.StatusCode >= 300 {
			return time.Time{}, false
		}
		lm := resp.Header.Get("Last-Modified")
		if lm == "" {
			return time.Time{}, false
		}
		t, err := http.ParseTime(lm)
		if err != nil {
			return time.Time{}, false
		}
		return t, true
	}
	if t, ok := do(http.MethodHead); ok {
		return t, true
	}
	// 部分 CDN 拒 HEAD，退到 Range GET。
	return do(http.MethodGet)
}

func firstVariantURL(content, base string) string {
	lines := strings.Split(content, "\n")
	for i, line := range lines {
		line = strings.TrimSpace(line)
		if strings.HasPrefix(line, "#EXT-X-STREAM-INF") && i+1 < len(lines) {
			next := strings.TrimSpace(lines[i+1])
			if next != "" && !strings.HasPrefix(next, "#") {
				return resolveURL(base, next)
			}
		}
	}
	return ""
}

func absolutizeURIs(content, base string) string {
	lines := strings.Split(content, "\n")
	for i, line := range lines {
		trim := strings.TrimSpace(line)
		if trim == "" || strings.HasPrefix(trim, "#") {
			continue
		}
		lines[i] = resolveURL(base, trim)
	}
	return strings.Join(lines, "\n")
}

// tagURIRe 匹配 #EXT-X-KEY / #EXT-X-MAP 等行里的 URI="…"。
var tagURIRe = regexp.MustCompile(`(?i)\bURI="([^"]+)"`)

func absolutizeTagURIs(content, base string) string {
	if base == "" || !strings.Contains(strings.ToUpper(content), "URI=") {
		return content
	}
	return tagURIRe.ReplaceAllStringFunc(content, func(m string) string {
		sub := tagURIRe.FindStringSubmatch(m)
		if len(sub) < 2 {
			return m
		}
		raw := sub[1]
		if raw == "" || strings.HasPrefix(raw, "data:") {
			return m
		}
		if strings.HasPrefix(raw, "http://") || strings.HasPrefix(raw, "https://") {
			return m
		}
		return `URI="` + resolveURL(base, raw) + `"`
	})
}

func resolveURL(base, ref string) string {
	if strings.HasPrefix(ref, "http://") || strings.HasPrefix(ref, "https://") {
		return ref
	}
	bu, err := url.Parse(base)
	if err != nil {
		return ref
	}
	ru, err := url.Parse(ref)
	if err != nil {
		return ref
	}
	return bu.ResolveReference(ru).String()
}

var imageExts = []string{".png", ".jpg", ".jpeg", ".gif", ".webp", ".bmp"}

func stripNonVideoSegments(content string) string {
	lines := strings.Split(content, "\n")
	out := make([]string, 0, len(lines))
	for i := 0; i < len(lines); i++ {
		line := lines[i]
		trim := strings.TrimSpace(line)
		if strings.HasPrefix(trim, "#EXTINF") && i+1 < len(lines) {
			uri := strings.ToLower(mediaBase(lines[i+1]))
			skip := false
			for _, ext := range imageExts {
				if strings.Contains(uri, ext) {
					skip = true
					break
				}
			}
			if skip {
				i++ // skip URI
				continue
			}
		}
		out = append(out, line)
	}
	return strings.Join(out, "\n")
}

func countSegments(content string) int {
	n := 0
	for _, line := range strings.Split(content, "\n") {
		trim := strings.TrimSpace(line)
		if trim == "" || strings.HasPrefix(trim, "#") {
			continue
		}
		n++
	}
	return n
}

func convertRelativeTsToAbsolute(content, base string) string {
	return absolutizeURIs(content, base)
}
