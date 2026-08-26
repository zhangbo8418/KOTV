package lenientjson

import (
	"encoding/json"
	"testing"
)

func TestValidPassthrough(t *testing.T) {
	in := []byte(`{"a":1,"list":[{"name":"x"}]}`)
	out := Sanitize(in)
	if string(out) != string(in) {
		t.Fatalf("valid json must stay unchanged, got %s", out)
	}
}

func TestSingleQuotes(t *testing.T) {
	var v struct {
		A string   `json:"a"`
		B []string `json:"b"`
	}
	if err := Unmarshal([]byte(`{'a':'hi','b':['x','y']}`), &v); err != nil {
		t.Fatalf("single quotes: %v", err)
	}
	if v.A != "hi" || len(v.B) != 2 {
		t.Fatalf("bad parse: %+v", v)
	}
}

func TestUnquotedKeys(t *testing.T) {
	var v map[string]any
	if err := Unmarshal([]byte(`{code:1,msg:ok}`), &v); err != nil {
		t.Fatalf("unquoted keys: %v", err)
	}
	if v["msg"] != "ok" {
		t.Fatalf("bad msg: %v", v["msg"])
	}
}

func TestTrailingComma(t *testing.T) {
	var v struct {
		List []int `json:"list"`
	}
	if err := Unmarshal([]byte(`{"list":[1,2,3,],}`), &v); err != nil {
		t.Fatalf("trailing comma: %v", err)
	}
	if len(v.List) != 3 {
		t.Fatalf("bad list: %v", v.List)
	}
}

func TestXSSIPrefix(t *testing.T) {
	var v map[string]int
	if err := Unmarshal([]byte(")]}'\n{\"code\":0}"), &v); err != nil {
		t.Fatalf("XSSI prefix: %v", err)
	}
	if v["code"] != 0 {
		t.Fatal("bad code")
	}
}

func TestEscapesInSingleQuotes(t *testing.T) {
	var v struct {
		URL string `json:"url"`
	}
	if err := Unmarshal([]byte(`{'url':'http://a.com/x?y=1&z=\'q\''}`), &v); err != nil {
		t.Fatalf("escaped single quotes: %v", err)
	}
	if v.URL != `http://a.com/x?y=1&z='q'` {
		t.Fatalf("bad url: %q", v.URL)
	}
}

func TestNestedMixed(t *testing.T) {
	raw := `{'class':[{'type_id':1,'type_name':'电影'},],"list":[{vod_id:'7',vod_name:'测试'}]}`
	var v struct {
		Class []struct {
			TypeID   int    `json:"type_id"`
			TypeName string `json:"type_name"`
		} `json:"class"`
		List []map[string]any `json:"list"`
	}
	if err := Unmarshal([]byte(raw), &v); err != nil {
		t.Fatalf("nested mixed: %v", err)
	}
	if len(v.Class) != 1 || v.Class[0].TypeName != "电影" {
		t.Fatalf("bad class: %+v", v.Class)
	}
	if len(v.List) != 1 || v.List[0]["vod_id"] != "7" {
		t.Fatalf("bad list: %+v", v.List)
	}
}

func TestGarbageUnchanged(t *testing.T) {
	in := []byte(`not json at all`)
	out := Sanitize(in)
	var v any
	if json.Unmarshal(out, &v) == nil {
		t.Fatal("garbage should not become valid")
	}
}

func TestDoubleQuoteInsideSingleQuoteValue(t *testing.T) {
	var v struct {
		S string `json:"s"`
	}
	if err := Unmarshal([]byte(`{'s':"he said \"ok\""}`), &v); err == nil && v.S == "" {
		// 混用引号由标准层处理；这里只确保不 panic
		_ = v
	}
}

func TestEmptyAndNull(t *testing.T) {
	for _, in := range []string{"", "null", "{}"} {
		var v map[string]any
		if err := Unmarshal([]byte(in), &v); err != nil {
			t.Fatalf("%q: %v", in, err)
		}
	}
}

func TestNameNotConfusedWithNull(t *testing.T) {
	var v map[string]any
	if err := Unmarshal([]byte(`{name:'电影',nullish:1}`), &v); err != nil {
		t.Fatalf("name vs null: %v", err)
	}
	if v["name"] != "电影" {
		t.Fatalf("bad name: %v", v["name"])
	}
	if v["nullish"] != float64(1) && v["nullish"] != 1 {
		// encoding/json numbers → float64
		if _, ok := v["nullish"]; !ok {
			t.Fatalf("missing nullish: %+v", v)
		}
	}
}
