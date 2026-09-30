package util

import (
	"testing"
	"time"
)

func TestDeviceLocation_IANA(t *testing.T) {
	cases := []string{"Asia/Shanghai", "America/New_York", "Europe/London", "Pacific/Auckland"}
	for _, tz := range cases {
		t.Run(tz, func(t *testing.T) {
			t.Setenv("KOTV_TZ", tz)
			t.Setenv("TZ", "UTC")
			t.Setenv("KOTV_TZ_OFFSET_MS", "")
			loc := DeviceLocation()
			if loc.String() != tz {
				t.Fatalf("loc=%s want %s", loc, tz)
			}
			summer := time.Date(2024, 7, 1, 12, 0, 0, 0, time.UTC)
			winter := time.Date(2024, 1, 1, 12, 0, 0, 0, time.UTC)
			_, offS := summer.In(loc).Zone()
			_, offW := winter.In(loc).Zone()
			if tz == "America/New_York" && offS == offW {
				t.Fatalf("New_York should differ DST: summer=%d winter=%d", offS, offW)
			}
			if tz == "Asia/Shanghai" && offS != 8*3600 {
				t.Fatalf("Shanghai offset=%d", offS)
			}
		})
	}
}

func TestDeviceLocation_OffsetFallback(t *testing.T) {
	t.Setenv("KOTV_TZ", "Not/AZone")
	t.Setenv("TZ", "UTC")
	t.Setenv("KOTV_TZ_OFFSET_MS", "28800000")
	loc := DeviceLocation()
	wall := time.Date(2024, 6, 1, 5, 34, 0, 0, time.UTC).In(loc)
	if wall.Hour() != 13 || wall.Minute() != 34 {
		t.Fatalf("wall=%s want 13:34", wall.Format("15:04"))
	}
}

func TestDeviceLocation_InvalidFallsBack(t *testing.T) {
	t.Setenv("KOTV_TZ", "Not/AZone")
	t.Setenv("TZ", "UTC")
	t.Setenv("KOTV_TZ_OFFSET_MS", "")
	loc := DeviceLocation()
	if loc == nil {
		t.Fatal("nil")
	}
}
