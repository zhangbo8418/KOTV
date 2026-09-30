package util

import (
	"os"
	"strconv"
	"strings"
	"time"

	// 安卓 sidecar 无系统 zoneinfo；嵌入后才能 LoadLocation(IANA)。
	_ "time/tzdata"
)

// DeviceLocation 设备默认时区，对应 FongMi ZoneId.systemDefault()。
//
// 安卓上 Go time.Local 常为 UTC。优先 KOTV_TZ=IANA（经 tzdata，含夏令时）；
// LoadLocation 失败时再用 KOTV_TZ_OFFSET_MS（Java getOffset → FixedZone），
// 避免旧 so / 缺 zoneinfo 时 EPG 再偏 8 小时。
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
	if raw := strings.TrimSpace(os.Getenv("KOTV_TZ_OFFSET_MS")); raw != "" {
		if ms, err := strconv.Atoi(raw); err == nil {
			return time.FixedZone("device", ms/1000)
		}
	}
	return time.Local
}
