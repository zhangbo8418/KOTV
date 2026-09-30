package util

import (
	"testing"
	"time"
)

func TestDeviceLocation_OffsetMs(t *testing.T) {
	t.Setenv("KOTV_TZ", "")
	t.Setenv("TZ", "UTC")
	t.Setenv("KOTV_TZ_OFFSET_MS", "28800000") // CST +8
	loc := DeviceLocation()
	now := time.Date(2024, 6, 1, 5, 34, 0, 0, time.UTC)
	wall := now.In(loc)
	if wall.Hour() != 13 || wall.Minute() != 34 {
		t.Fatalf("wall=%s want 13:34", wall.Format("15:04"))
	}
}

func TestDeviceLocation_NamedZone(t *testing.T) {
	t.Setenv("KOTV_TZ", "Asia/Shanghai")
	t.Setenv("KOTV_TZ_OFFSET_MS", "")
	loc := DeviceLocation()
	if _, err := time.LoadLocation("Asia/Shanghai"); err != nil {
		t.Skip(err)
	}
	if loc.String() != "Asia/Shanghai" {
		t.Fatalf("loc=%s", loc)
	}
}
