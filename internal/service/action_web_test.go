package service

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestMergeActionWebJSON_PreservesWeb(t *testing.T) {
	raw := `{"msg":"hi","web":{"url":"http://127.0.0.1:9/website","mode":"view"},"list":[]}`
	encoded := `{"msg":"hi","list":[]}`
	out := mergeActionWebJSON(raw, encoded)
	var m map[string]any
	if err := json.Unmarshal([]byte(out), &m); err != nil {
		t.Fatal(err)
	}
	web, ok := m["web"].(map[string]any)
	if !ok {
		t.Fatalf("web missing: %s", out)
	}
	if u, _ := web["url"].(string); !strings.Contains(u, "/website") {
		t.Fatalf("url=%v", web["url"])
	}
	if mergeActionWebJSON(`{"msg":"x"}`, encoded) != encoded {
		t.Fatal("without web should keep encoded")
	}
}
