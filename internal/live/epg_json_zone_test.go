package live

import (
	"testing"
	"time"
)

func TestParseEPG_UsesZone(t *testing.T) {
	tokyo, err := time.LoadLocation("Asia/Tokyo")
	if err != nil {
		t.Fatal(err)
	}
	raw := `{"date":"2024-01-01","list":[{"title":"A","start":"12:00","end":"13:00"}]}`
	epg := ParseEPG(raw, "k", "2024-01-01", tokyo)
	if len(epg.List) != 1 {
		t.Fatalf("list=%d", len(epg.List))
	}
	want := time.Date(2024, 1, 1, 12, 0, 0, 0, tokyo).UnixMilli()
	if epg.List[0].StartTime != want {
		t.Fatalf("StartTime=%d want %d (local=%d)", epg.List[0].StartTime, want,
			time.Date(2024, 1, 1, 12, 0, 0, 0, time.Local).UnixMilli())
	}
}
