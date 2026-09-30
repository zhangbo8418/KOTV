package util

import (
	"os"
	"strings"
	"time"

	// 安卓 sidecar 无系统 zoneinfo；嵌入后才能 LoadLocation(IANA)。
	_ "time/tzdata"
)

// DeviceLocation 设备默认时区，对应 FongMi ZoneId.systemDefault()。
//
// 安卓上 Go time.Local 常为 UTC。只用 KOTV_TZ / TZ 的 IANA 名（经 tzdata）；
// LoadLocation 失败则回落 time.Local，不做固定偏移兜底，便于发现时区注入问题。
func DeviceLocation() *time.Location {
	for _, key := range []string{"KOTV_TZ", "TZ"} {
		tz := strings.TrimSpace(os.Getenv(key))
		if tz == "" {
			continue
		}
		if key == "TZ" && (strings.EqualFold(tz, "UTC") || tz == ":UTC") {
			continue
		}
		if loc, err := time.LoadLocation(tz); err == nil && loc != nil {
			return loc
		}
	}
	return time.Local
}
