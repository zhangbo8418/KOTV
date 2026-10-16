package model

import (
	"encoding/json"
	"testing"
)

func TestResolveStyleLandCircleAndCap(t *testing.T) {
	land := Vod{Land: "1"}
	got := land.ResolveStyle(RectView())
	if got.Type != "rect" || got.Ratio != 1.33 {
		t.Fatalf("land default = %+v", got)
	}

	circle := Vod{Circle: "1"}
	got = circle.ResolveStyle(RectView())
	if got.Type != "oval" || got.Ratio != 1 {
		t.Fatalf("circle default = %+v", got)
	}

	capped := Vod{Style: &Style{Type: "rect", Ratio: "9"}}
	got = capped.ResolveStyle(RectView())
	if got.Ratio != 4 || !got.IsLand() {
		t.Fatalf("cap = %+v", got)
	}

	plain := Vod{}
	got = plain.ResolveStyle(ViewStyle{})
	if got.Type != "rect" || got.Ratio != 0.75 {
		t.Fatalf("fallback = %+v", got)
	}
}

func TestPageViewStyleItemOverridesSite(t *testing.T) {
	site := &Style{Type: "rect", Ratio: "0.75"}
	empty := PageViewStyle(nil, site)
	if empty.Ratio != 0.75 {
		t.Fatalf("empty page = %+v", empty)
	}
	list := []Vod{{Land: "1", Ratio: "2"}}
	page := PageViewStyle(list, site)
	if page.Type != "rect" || page.Ratio != 2 || !page.IsLand() {
		t.Fatalf("item page = %+v", page)
	}
	own := Vod{Style: &Style{Type: "oval", Ratio: "1"}, Land: "1"}
	got := own.ResolveStyle(RectView())
	if got.Type != "oval" || got.Ratio != 1 {
		t.Fatalf("item style wins = %+v", got)
	}
}

func TestCategoryPageStyleFolderAndTypeLand(t *testing.T) {
	site := &Style{Type: "rect", Ratio: "0.75"}
	if got := CategoryPageStyle(nil, site, true, "", "", ""); !got.IsList() {
		t.Fatalf("empty folder = %+v", got)
	}
	plain := CategoryPageStyle([]Vod{{}}, site, true, "", "", "")
	if !plain.IsList() {
		t.Fatalf("plain item keeps list = %+v", plain)
	}
	icons := CategoryPageStyle([]Vod{{Style: &Style{Type: "rect", Ratio: "1.33"}}}, site, true, "", "", "")
	if icons.Type != "rect" || icons.Ratio != 1.33 || !icons.IsLand() {
		t.Fatalf("item overrides folder list = %+v", icons)
	}
	land := CategoryPageStyle(nil, nil, false, "1", "", "")
	if land.Type != "rect" || land.Ratio != 1.33 {
		t.Fatalf("type land = %+v", land)
	}
}

func TestTypeKeepsLandRatio(t *testing.T) {
	var typ Type
	raw := []byte(`{"type_id":"cfg","type_name":"配置","type_flag":"1","land":1,"ratio":1.33}`)
	if err := json.Unmarshal(raw, &typ); err != nil {
		t.Fatal(err)
	}
	if typ.TypeFlag != "1" || typ.Land.String() != "1" || typ.Ratio.String() == "" {
		t.Fatalf("type = %+v", typ)
	}
	if _, ok := FindType([]Type{typ}, "cfg"); !ok {
		t.Fatal("find type")
	}
}
