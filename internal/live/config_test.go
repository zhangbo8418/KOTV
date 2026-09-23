package live

import (
	"encoding/json"
	"testing"
)

func TestParseConfigMeta_RootSpiderAndNet(t *testing.T) {
	raw := `{"spider":"http://x/spider.jar","headers":[{"host":"*","header":{"X":"1"}}],"hosts":["a=1.1.1.1"],"lives":[{"name":"A","api":"csp_X","url":"http://u"}]}`
	meta, ok := ParseConfigMeta(raw)
	if !ok {
		t.Fatal("expected config meta")
	}
	if meta.Spider != "http://x/spider.jar" {
		t.Fatalf("spider=%q", meta.Spider)
	}
	if len(meta.Headers) == 0 || len(meta.Hosts) == 0 {
		t.Fatalf("headers/hosts missing: %s / %s", meta.Headers, meta.Hosts)
	}
	if len(meta.Lives) != 1 || meta.Lives[0].Name != "A" {
		t.Fatalf("lives=%+v", meta.Lives)
	}
	// 空 jar 继承在 Service.Load；此处只验解析。
	var probe map[string]json.RawMessage
	if err := json.Unmarshal([]byte(raw), &probe); err != nil {
		t.Fatal(err)
	}
	if _, ok := probe["proxy"]; ok {
		t.Fatal("fixture has no proxy")
	}
}

func TestParseConfigMeta_PlainM3UObjectRejected(t *testing.T) {
	// 单个频道 JSON 数组不是根配置对象
	if _, ok := ParseConfigMeta(`[{"name":"G","channel":[]}]`); ok {
		t.Fatal("array must not be config meta")
	}
}
