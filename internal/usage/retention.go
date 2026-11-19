package usage

import (
	"strconv"
	"strings"
	"time"

	"github.com/bobo/KOTV/internal/settings"
)

// MaybePurge 按 usageRetentionDays 清理原始事件（默认 30）。
func MaybePurge() {
	if store == nil {
		return
	}
	days := 30
	if v := strings.TrimSpace(settings.Get(settings.Type("usageRetentionDays"))); v != "" {
		if n, err := strconv.Atoi(v); err == nil && n > 0 {
			days = n
		}
	}
	before := time.Now().AddDate(0, 0, -days).UnixMilli()
	_ = store.PurgeOldUsageEvents(before)
}
