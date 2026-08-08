package m3u8

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"path"
	"regexp"
	"strings"
	"time"

	"github.com/bobo/KOTV/internal/hostclient"
	"github.com/bobo/KOTV/internal/settings"
)

func jsonUnmarshal(raw string, v interface{}) error {
	return json.Unmarshal([]byte(raw), v)
}

var httpClient = &http.Client{Timeout: 20 * time.Second}

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
	cfg := DefaultConfig()
	if raw := settings.GetM3U8FilterConfigJSON(); raw != "" {
		_ = jsonUnmarshal(raw, &cfg)
	}
	filtered := NewFilter(cfg).Process(content)
	filtered = stripNonVideoSegments(filtered)
	filtered = keepDominantSegmentGroup(filtered)
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

func fetch(u string, headers map[string]string) (string, error) {
	req, err := http.NewRequest(http.MethodGet, u, nil)
	if err != nil {
		return "", err
	}
	for k, v := range headers {
		req.Header.Set(k, v)
	}
	if req.Header.Get("User-Agent") == "" {
		req.Header.Set("User-Agent", "Mozilla/5.0 KOTV")
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
// 本地 cached_m3u8 代理后，相对 enc.key 会错误落到 127.0.0.1，必须先补成绝对地址。
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
			uri := strings.ToLower(strings.TrimSpace(lines[i+1]))
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

func keepDominantSegmentGroup(content string) string {
	type seg struct {
		idx  int
		dir  string
		line string
	}
	lines := strings.Split(content, "\n")
	var segs []seg
	for i, line := range lines {
		trim := strings.TrimSpace(line)
		if trim == "" || strings.HasPrefix(trim, "#") {
			continue
		}
		if !strings.HasPrefix(trim, "http") {
			continue
		}
		u, err := url.Parse(trim)
		if err != nil {
			continue
		}
		dir := path.Dir(u.Path)
		segs = append(segs, seg{i, dir, trim})
	}
	if len(segs) < 10 {
		return content
	}
	counts := map[string]int{}
	for _, s := range segs {
		counts[s.dir]++
	}
	best, bestN := "", 0
	for d, n := range counts {
		if n > bestN {
			best, bestN = d, n
		}
	}
	if bestN < len(segs)*2/3 || bestN == len(segs) {
		return content
	}
	drop := map[int]bool{}
	for _, s := range segs {
		if s.dir != best {
			drop[s.idx] = true
			if s.idx > 0 && strings.HasPrefix(strings.TrimSpace(lines[s.idx-1]), "#EXTINF") {
				drop[s.idx-1] = true
			}
		}
	}
	out := make([]string, 0, len(lines))
	for i, line := range lines {
		if drop[i] {
			continue
		}
		out = append(out, line)
	}
	return strings.Join(out, "\n")
}

func convertRelativeTsToAbsolute(content, base string) string {
	return absolutizeURIs(content, base)
}
