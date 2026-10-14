package live

import (
	"strings"

	"github.com/bobo/KOTV/internal/model"
	"github.com/bobo/KOTV/internal/parse"
	"github.com/bobo/KOTV/internal/source"
	"github.com/bobo/KOTV/internal/thunder"
)

// URLNeedsEnginePlay 仅按地址形态判断：空串 / 二次解析前缀 / 专用源 / 磁力。
func URLNeedsEnginePlay(rawURL string) bool {
	raw := strings.TrimSpace(rawURL)
	if raw == "" {
		return true
	}
	lower := strings.ToLower(raw)
	if strings.HasPrefix(lower, "json:") ||
		strings.HasPrefix(lower, "parse:") ||
		strings.HasPrefix(lower, "video:") {
		return true
	}
	return source.Match(raw) || thunder.Match(raw)
}

// NeedsEnginePlay 客户端不能直接打开该线路，须经 APILivePlay（二次解析 / 专用源 / 磁力）。
// 判定集中在引擎，UI 只看 Load 下发的 urls 是否非空。
func NeedsEnginePlay(ch *model.LiveChannel, rawURL string) bool {
	if ch != nil && ch.Parse == 1 {
		return true
	}
	return URLNeedsEnginePlay(rawURL)
}

// VodNeedsEnginePlay 点播集是否须经 APIPlay（爬虫 / PlayURL / 磁力 / 非直链形态）。
// 可直开：type 0/1/2、无 PlayURL、地址为视频直链且无专用前缀。
func VodNeedsEnginePlay(site model.Site, rawURL string, rules []model.Rule) bool {
	raw := strings.TrimSpace(rawURL)
	if URLNeedsEnginePlay(raw) {
		return true
	}
	if thunder.Match(raw) {
		return true
	}
	tid := site.TypeID()
	if tid == 3 || tid == 4 {
		return true
	}
	if tid != 0 && tid != 1 && tid != 2 {
		return true
	}
	if strings.TrimSpace(site.PlayURL) != "" {
		return true
	}
	if !parse.IsVideoFormatRules(raw, rules) {
		return true
	}
	return false
}
