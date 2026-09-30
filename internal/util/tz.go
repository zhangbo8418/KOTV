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
// 安卓上 Go time.Local 常为 UTC（无 /etc/localtime）。由 Java 注入
// KOTV_TZ=TimeZone.getDefault().id（如 Asia/Shanghai、America/New_York），
// 经 time/tzdata 做 IANA 解析；失败再试 TZ，最后 time.Local。
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
