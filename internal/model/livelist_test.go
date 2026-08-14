package model

import (
	"encoding/json"
	"testing"
)

func TestLiveListUnmarshal(t *testing.T) {
	var api struct {
		Lives LiveList `json:"lives"`
	}
	if err := json.Unmarshal([]byte(`{"lives":[{"name":"卫视","url":"http://a/live.m3u"}]}`), &api); err != nil {
		t.Fatal(err)
	}
	if len(api.Lives) != 1 || api.Lives[0].Name != "卫视" {
		t.Fatalf("array object: %+v", api.Lives)
	}

	api.Lives = nil
	if err := json.Unmarshal([]byte(`{"lives":"http://b/lives.json"}`), &api); err != nil {
		t.Fatal(err)
	}
	if len(api.Lives) != 1 || api.Lives[0].URL != "http://b/lives.json" {
		t.Fatalf("string url: %+v", api.Lives)
	}

	api.Lives = nil
	if err := json.Unmarshal([]byte(`{"lives":{"name":"单源","url":"http://c/x.m3u"}}`), &api); err != nil {
		t.Fatal(err)
	}
	if len(api.Lives) != 1 || api.Lives[0].Name != "单源" {
		t.Fatalf("single object: %+v", api.Lives)
	}
}
