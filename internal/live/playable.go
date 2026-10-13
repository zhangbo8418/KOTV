package live

import (
	"strings"

	"github.com/bobo/KOTV/internal/model"
	"github.com/bobo/KOTV/internal/source"
)

// NeedsEnginePlay 客户端不能直接打开该线路，须经 APILivePlay（二次解析 / 专用源）。
// 判定集中在引擎，UI 只看 Load 下发的 urls 是否非空。
func NeedsEnginePlay(ch *model.LiveChannel, rawURL string) bool {
	if ch != nil && ch.Parse == 1 {
		return true
	}
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
	return source.Match(raw)
}
