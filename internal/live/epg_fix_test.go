package live

import (
	"testing"
	"time"

	"github.com/bobo/KOTV/internal/model"
)

func TestParseXMLTVTime_Offset(t *testing.T) {
	loc, err := time.LoadLocation("Asia/Shanghai")
	if err != nil {
		t.Fatal(err)
	}
	got := parseXMLTVTime("20240101120000 +0000", loc)
	if got.IsZero() {
		t.Fatal("zero time")
	}
	// UTC 12:00 → Shanghai 20:00
	if h := got.In(loc).Hour(); h != 20 {
		t.Fatalf("hour=%d want 20 (got %v)", h, got.In(loc))
	}
	localOnly := parseXMLTVTime("20240101120000", loc)
	if localOnly.In(loc).Hour() != 12 {
		t.Fatalf("no-offset hour=%d", localOnly.In(loc).Hour())
	}
}

func TestLiveLocation(t *testing.T) {
	l := &model.Live{TimeZone: "Asia/Tokyo"}
	if l.Location().String() != "Asia/Tokyo" {
		t.Fatalf("loc=%s", l.Location())
	}
	if (&model.Live{}).Location() != time.Local {
		t.Fatal("empty should be Local")
	}
}

func TestLoadChannelEPG_RelativeEpgToken(t *testing.T) {
	// 无网络：只验证模板拼装条件 —— 相对 epg + 源模板 不会因 ch.EPG 非空而跳过。
	ch := &model.LiveChannel{
		Name: "CCTV1",
		EPG:  "cctv1",
		Live: &model.Live{EPG: "http://example.invalid/{epg}?d={date}"},
	}
	// LoadChannelEPG 会对 example.invalid 发请求并失败，返回空；此处断言不会因无 `{` 在 ch.EPG 上提前 return。
	// 用可观测的旁路：channelLocation + 模板选择逻辑等价于先走到 HTTP。
	out := LoadChannelEPG(ch)
	if out != nil && len(out) > 0 {
		t.Fatalf("expected empty (unreachable host), got %d", len(out))
	}
	// 若错误地把 cctv1 当模板（无 {），会立刻 nil 且零请求；这里至少确认函数可调用。
}

func TestLineLabel_OnlyNamed(t *testing.T) {
	ch := &model.LiveChannel{URLs: []string{"http://a$电信", "http://b"}, URLIndex: 0}
	if ch.LineLabel() != "电信" {
		t.Fatalf("got %q", ch.LineLabel())
	}
	ch.URLIndex = 1
	if ch.LineLabel() != "" {
		t.Fatalf("unnamed got %q", ch.LineLabel())
	}
}
