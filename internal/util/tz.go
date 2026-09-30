package util

import (
	"os"
	"strconv"
	"strings"
	"time"
)

// DeviceLocation 设备墙钟时区。
//
// 安卓 sidecar 上 Go time.Local 常为 UTC（无 /etc/localtime；仅设 TZ=IANA
// 且未带上 zoneinfo 时 LoadLocation 失败也会落回 UTC）。优先 KOTV_TZ，
// 否则用 KOTV_TZ_OFFSET_MS（Java getOffset，FixedZone，不依赖 zoneinfo）。
func DeviceLocation() *time.Location {
	if tz := strings.TrimSpace(os.Getenv("KOTV_TZ")); tz != "" {
		if loc, err := time.LoadLocation(tz); err == nil && loc != nil {
			return loc
		}
	}
	if tz := strings.TrimSpace(os.Getenv("TZ")); tz != "" && !strings.EqualFold(tz, "UTC") && tz != ":UTC" {
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
