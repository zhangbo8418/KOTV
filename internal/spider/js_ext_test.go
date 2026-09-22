package spider

import "testing"

func TestJsExtValue_OnlyObjectsParsed(t *testing.T) {
	if v, ok := jsExtValue(` {"a":1,"b":"x"} `).(map[string]interface{}); !ok || v["b"] != "x" {
		t.Fatalf("object must parse, got %#v", v)
	}
	for _, raw := range []string{"[1,2]", `["a","b"]`, "123", "http://x/ext.json", "a,b,c", "{not json", ""} {
		if v, ok := jsExtValue(raw).(string); !ok || v != raw {
			t.Fatalf("%q must stay string, got %#v", raw, jsExtValue(raw))
		}
	}
}
