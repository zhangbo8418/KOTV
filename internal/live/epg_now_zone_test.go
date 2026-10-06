package live

import (
	"testing"
	"time"

	"github.com/bobo/KOTV/internal/util"
)

// 复现：墙钟 JSON 按 UTC 解析时，CST 11:33 会被标成 03:30 档「正在播出」。
func TestIsInRange_WallClockUsesZoneNotUTC(t *testing.T) {
	shanghai, err := time.LoadLocation("Asia/Shanghai")
	if err != nil {
		t.Fatal(err)
	}
	// 固定「现在」为 2024-06-01 11:33 CST == 03:33 UTC。
	nowUTC := time.Date(2024, 6, 1, 3, 33, 0, 0, time.UTC)
	raw := `{"date":"2024-06-01","list":[
		{"title":"wrong-if-utc","start":"03:30","end":"04:00"},
		{"title":"current","start":"11:30","end":"12:00"}
	]}`

	asUTC := ParseEPG(raw, "k", "2024-06-01", time.UTC)
	asSH := ParseEPG(raw, "k", "2024-06-01", shanghai)

	inRange := func(list []EpgData, title string) bool {
		for _, p := range list {
			if p.Title != title {
				continue
			}
			return p.StartTime <= nowUTC.UnixMilli() && nowUTC.UnixMilli() <= p.EndTime
		}
		return false
	}

	if !inRange(asUTC.List, "wrong-if-utc") {
		t.Fatal("sanity: UTC zone should match 03:30 slot at 03:33 UTC")
	}
	if inRange(asSH.List, "wrong-if-utc") {
		t.Fatal("Asia/Shanghai must not treat 03:30 as current at 11:33 CST")
	}
	if !inRange(asSH.List, "current") {
		t.Fatal("Asia/Shanghai should mark 11:30~12:00 as current at 11:33 CST")
	}
	if asSH.List[1].Start != "11:30" || asSH.List[1].End != "12:00" {
		t.Fatalf("display=%s~%s", asSH.List[1].Start, asSH.List[1].End)
	}
}

// DeviceLocation 读 KOTV_TZ 的 IANA 名，含夏令时。
func TestParseEPG_DeviceLocationIANA(t *testing.T) {
	t.Setenv("KOTV_TZ", "America/New_York")
	t.Setenv("TZ", "UTC")
	zone := util.DeviceLocation()
	if zone.String() != "America/New_York" {
		t.Fatalf("zone=%s", zone)
	}
	// 2024-07-01 16:00 EDT = 20:00 UTC；节目 16:00~17:00 应为 now。
	raw := `{"date":"2024-07-01","list":[{"title":"NY","start":"16:00","end":"17:00"}]}`
	epg := ParseEPG(raw, "k", "2024-07-01", zone)
	now := time.Date(2024, 7, 1, 20, 30, 0, 0, time.UTC).UnixMilli()
	if len(epg.List) != 1 || !(epg.List[0].StartTime <= now && now <= epg.List[0].EndTime) {
		t.Fatalf("Start=%d End=%d now=%d display=%s~%s",
			epg.List[0].StartTime, epg.List[0].EndTime, now, epg.List[0].Start, epg.List[0].End)
	}
}
