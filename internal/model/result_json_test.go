package model

import (
	"testing"
)

func TestDecodeResultJSONLenient(t *testing.T) {
	raw := `{'class':[{id:'1',name:'电影'},],'list':[{vod_id:7,vod_name:'测试',}],danmaku:[{url:'http://d.com/a.xml'}]}`
	r, err := DecodeResultJSON(raw)
	if err != nil {
		t.Fatalf("DecodeResultJSON: %v", err)
	}
	if len(r.Types) != 1 || r.Types[0].TypeName != "电影" || r.Types[0].TypeID.String() != "1" {
		t.Fatalf("bad class: %+v", r.Types)
	}
	if len(r.List) != 1 || r.List[0].VodName != "测试" || r.List[0].VodID.String() != "7" {
		t.Fatalf("bad list: %+v", r.List)
	}
	if r.Danmaku.String() != "http://d.com/a.xml" {
		t.Fatalf("bad danmaku: %q", r.Danmaku)
	}
}

func TestFromTypeSoftFail(t *testing.T) {
	r, err := FromType(1, "not-json")
	if err != nil {
		t.Fatalf("expected soft fail, got err: %v", err)
	}
	if !r.Success || len(r.List) != 0 {
		t.Fatalf("expected empty success, got %+v", r)
	}
}
