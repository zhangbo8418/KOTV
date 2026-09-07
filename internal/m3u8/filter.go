package m3u8

import (
	"math"
	"net/url"
	"path"
	"regexp"
	"strconv"
	"strings"
	"time"
)

// Filter 按 #EXT-X-DISCONTINUITY 分段过滤插播广告。
// 不依赖切片文件名序号连续（哈希名 / 非数字名同样适用）。
// 规则思路参考 HLS(m3u8) 广告移除脚本，本实现为独立编写。
type Filter struct {
	cfg FilterConfig

	removedDuration float64
	removedGroups   int
	reverted        bool
	usedMild        bool
}

func NewFilter(cfg FilterConfig) *Filter {
	return &Filter{cfg: cfg.normalized()}
}

func (f *Filter) RemovedDuration() float64 { return f.removedDuration }
func (f *Filter) RemovedGroups() int       { return f.removedGroups }
func (f *Filter) Reverted() bool           { return f.reverted }
func (f *Filter) UsedMild() bool           { return f.usedMild }

var (
	extinfRe   = regexp.MustCompile(`(?i)#?EXTINF:\s*([0-9.]+)\s*,`)
	mediaURIRe = regexp.MustCompile(`(?im)^(.*\.(?:ts|m4s|mp4|jpg|jpeg|png))(?:\?|#|$)`)
)

type discChunk struct {
	raw          string
	duration     float64
	extinfs      []float64
	paths        []string
	lastModified time.Time // zero = unknown
	hasMedia     bool
}

// Apply 按配置档位过滤。智能：先结构删段，无改动或回滚则温和去断点；温和：只去 DISCONTINUITY。
func (f *Filter) Apply(content string, lastModifieds ...time.Time) string {
	f.usedMild = false
	switch f.cfg.Mode {
	case ModeMild:
		f.usedMild = true
		return StripDiscontinuityMarkers(content)
	default:
		out := f.Process(content, lastModifieds...)
		if out != content && !f.reverted {
			return out
		}
		// 结构过滤未改动或已回滚 → 温和兜底（不删切片）。
		mild := StripDiscontinuityMarkers(content)
		if mild != content {
			f.usedMild = true
			return mild
		}
		return content
	}
}

// StripDiscontinuityMarkers 只删除 #EXT-X-DISCONTINUITY（保留紧跟 PLAYLIST-TYPE 的那一行）。
// 不删媒体切片，避免误杀正片。
func StripDiscontinuityMarkers(content string) string {
	normalized := strings.ReplaceAll(strings.ReplaceAll(content, "\r\n", "\n"), "\r", "")
	if !strings.Contains(normalized, "#EXT-X-DISCONTINUITY") {
		return content
	}
	lines := strings.Split(normalized, "\n")
	out := make([]string, 0, len(lines))
	for i, line := range lines {
		trim := strings.TrimSpace(line)
		if strings.HasPrefix(trim, "#EXT-X-DISCONTINUITY") {
			if i > 0 && strings.HasPrefix(strings.TrimSpace(lines[i-1]), "#EXT-X-PLAYLIST-TYPE") {
				out = append(out, line)
			}
			continue
		}
		out = append(out, line)
	}
	joined := strings.Join(out, "\n")
	if strings.HasSuffix(normalized, "\n") && !strings.HasSuffix(joined, "\n") {
		joined += "\n"
	}
	return joined
}

// Process 结构过滤：按 DISCONTINUITY 分段删广告段组。lastModifieds 与分段一一对应。
func (f *Filter) Process(content string, lastModifieds ...time.Time) string {
	f.removedDuration = 0
	f.removedGroups = 0
	f.reverted = false

	normalized := strings.ReplaceAll(strings.ReplaceAll(content, "\r\n", "\n"), "\r", "")
	if !strings.Contains(normalized, "#EXT-X-DISCONTINUITY") {
		return content
	}

	parts := strings.Split(normalized, "#EXT-X-DISCONTINUITY")
	if len(parts) < 2 {
		return content
	}

	chunks := make([]discChunk, len(parts))
	for i, p := range parts {
		c := parseChunk(p)
		if i < len(lastModifieds) {
			c.lastModified = lastModifieds[i]
		}
		chunks[i] = c
	}

	suspiciousLM := map[int64]struct{}{}
	if f.cfg.UseLastModified {
		var samples []time.Time
		for _, c := range chunks {
			if !c.lastModified.IsZero() {
				samples = append(samples, c.lastModified)
			}
		}
		for _, t := range suspiciousLastModifieds(samples) {
			suspiciousLM[t.UnixMilli()] = struct{}{}
		}
	}

	// 永远保留第一段（片头正片 / 片头元数据）。
	kept := []string{chunks[0].raw}
	lastPath := ""
	if len(chunks[0].paths) > 0 {
		lastPath = chunks[0].paths[len(chunks[0].paths)-1]
	}
	maxDistance := 0
	removedDur := 0.0
	removedN := 0

	for i := 1; i < len(chunks); i++ {
		c := chunks[i]
		if !c.hasMedia {
			kept = append(kept, c.raw)
			continue
		}

		// 长段组：正片。
		if c.duration >= f.cfg.KeepMinDuration {
			kept = append(kept, c.raw)
			lastPath, maxDistance = updatePathStats(c.paths, lastPath, maxDistance)
			continue
		}

		remove := false
		// 齐 EXTINF 短突发（常见贴片）。
		if len(c.extinfs) > 0 && allSameFloat(c.extinfs) && c.duration < f.cfg.UniformShortMax {
			remove = true
		}
		// Last-Modified 落在「小时间簇」。
		if !remove && f.cfg.UseLastModified && !c.lastModified.IsZero() {
			if _, ok := suspiciousLM[c.lastModified.UnixMilli()]; ok {
				remove = true
			}
		}
		// 路径相对正片突然跳变（编辑距离）。
		if !remove && lastPath != "" && len(c.paths) > 0 {
			d := levenshtein(c.paths[0], lastPath)
			if maxDistance > 0 && maxDistance < 10 && d > maxDistance {
				remove = true
			}
		}
		// 路径特征（保守，不依赖序号）。
		if !remove && strongAdPath(c.paths) {
			remove = true
		}

		if remove {
			removedDur += c.duration
			removedN++
			continue
		}
		kept = append(kept, c.raw)
		lastPath, maxDistance = updatePathStats(c.paths, lastPath, maxDistance)
	}

	if removedN == 0 {
		return content
	}
	// 删太多 → 整单回滚，避免正片被砍成几十秒。
	if removedDur > f.cfg.MaxRemoveDuration {
		f.reverted = true
		f.removedDuration = removedDur
		f.removedGroups = removedN
		return content
	}
	if len(kept) < 2 {
		f.reverted = true
		f.removedDuration = removedDur
		f.removedGroups = removedN
		return content
	}

	f.removedDuration = removedDur
	f.removedGroups = removedN
	out := strings.Join(kept, "#EXT-X-DISCONTINUITY")
	if strings.HasSuffix(normalized, "\n") && !strings.HasSuffix(out, "\n") {
		out += "\n"
	}
	return out
}

func parseChunk(raw string) discChunk {
	c := discChunk{raw: raw}
	for _, m := range extinfRe.FindAllStringSubmatch(raw, -1) {
		if len(m) < 2 {
			continue
		}
		v, err := strconv.ParseFloat(m[1], 64)
		if err != nil {
			continue
		}
		c.extinfs = append(c.extinfs, v)
		c.duration += v
	}
	for _, m := range mediaURIRe.FindAllStringSubmatch(raw, -1) {
		if len(m) < 2 {
			continue
		}
		uri := strings.TrimSpace(m[1])
		if uri == "" || strings.HasPrefix(uri, "#") {
			continue
		}
		c.paths = append(c.paths, mediaPath(uri))
		c.hasMedia = true
	}
	return c
}

func updatePathStats(paths []string, lastPath string, maxDistance int) (string, int) {
	cur := lastPath
	maxD := maxDistance
	for _, p := range paths {
		if cur != "" {
			d := levenshtein(p, cur)
			if d > maxD {
				maxD = d
			}
		}
		cur = p
	}
	return cur, maxD
}

func allSameFloat(vs []float64) bool {
	if len(vs) == 0 {
		return false
	}
	first := vs[0]
	for _, v := range vs[1:] {
		if math.Abs(v-first) > 1e-6 {
			return false
		}
	}
	return true
}

func strongAdPath(paths []string) bool {
	for _, p := range paths {
		low := strings.ToLower(p)
		if strings.Contains(low, "adjump") ||
			strings.Contains(low, "/ad/") ||
			strings.Contains(low, "/ads/") ||
			strings.Contains(low, "advert") {
			return true
		}
	}
	return false
}

// suspiciousLastModifieds：按 24h 间隙分簇，长度 ≤3 的小簇视为可疑广告上传时间。
func suspiciousLastModifieds(times []time.Time) []time.Time {
	const gap = 24 * time.Hour
	if len(times) == 0 {
		return nil
	}
	sorted := append([]time.Time(nil), times...)
	for i := 0; i < len(sorted); i++ {
		for j := i + 1; j < len(sorted); j++ {
			if sorted[j].Before(sorted[i]) {
				sorted[i], sorted[j] = sorted[j], sorted[i]
			}
		}
	}
	var groups [][]time.Time
	cur := []time.Time{sorted[0]}
	for i := 1; i < len(sorted); i++ {
		if sorted[i].Sub(sorted[i-1]) < gap {
			cur = append(cur, sorted[i])
		} else {
			groups = append(groups, cur)
			cur = []time.Time{sorted[i]}
		}
	}
	groups = append(groups, cur)
	var out []time.Time
	for _, g := range groups {
		if len(g) <= 3 {
			out = append(out, g...)
		}
	}
	return out
}

func mediaPath(uri string) string {
	trim := strings.TrimSpace(uri)
	if i := strings.IndexAny(trim, "?#"); i >= 0 {
		trim = trim[:i]
	}
	if strings.Contains(trim, "://") {
		if u, err := url.Parse(trim); err == nil {
			return u.Path
		}
	}
	if !strings.HasPrefix(trim, "/") {
		return "/" + trim
	}
	return trim
}

// mediaBase 切片文件名（去 query）；供去图片伪装切片等使用。
func mediaBase(line string) string {
	trim := strings.TrimSpace(line)
	if trim == "" || strings.HasPrefix(trim, "#") {
		return trim
	}
	if i := strings.IndexAny(trim, "?#"); i >= 0 {
		trim = trim[:i]
	}
	if strings.Contains(trim, "://") {
		if u, err := url.Parse(trim); err == nil && u.Path != "" {
			return path.Base(u.Path)
		}
	}
	return path.Base(trim)
}

// IsMasterPlaylist 是否为多码率主列表。
func IsMasterPlaylist(content string) bool {
	return strings.Contains(content, "#EXT-X-STREAM-INF")
}

func levenshtein(a, b string) int {
	if a == b {
		return 0
	}
	la, lb := len(a), len(b)
	if la == 0 {
		return lb
	}
	if lb == 0 {
		return la
	}
	prev := make([]int, lb+1)
	cur := make([]int, lb+1)
	for j := 0; j <= lb; j++ {
		prev[j] = j
	}
	for i := 1; i <= la; i++ {
		cur[0] = i
		ca := a[i-1]
		for j := 1; j <= lb; j++ {
			cost := 1
			if ca == b[j-1] {
				cost = 0
			}
			del := prev[j] + 1
			ins := cur[j-1] + 1
			sub := prev[j-1] + cost
			cur[j] = del
			if ins < cur[j] {
				cur[j] = ins
			}
			if sub < cur[j] {
				cur[j] = sub
			}
		}
		prev, cur = cur, prev
	}
	return prev[lb]
}
