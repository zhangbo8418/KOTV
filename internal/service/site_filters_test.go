package service

import (
	"testing"

	"github.com/bobo/KOTV/internal/model"
)

func TestMergeFilterDefaults_OnlyInit(t *testing.T) {
	filters := []model.Filter{
		{
			Key:  "class",
			Name: "class",
			Value: []model.FilterItem{
				{N: "古装", V: "古装"},
				{N: "都市", V: "都市"},
			},
		},
		{
			Key:  "year",
			Name: "year",
			Init: "2024",
			Value: []model.FilterItem{
				{N: "2026", V: "2026"},
				{N: "2024", V: "2024"},
			},
		},
	}
	extend := map[string]string{}
	mergeFilterDefaults(extend, filters)
	if _, ok := extend["class"]; ok {
		t.Fatalf("no-init filter must not default to first value, got %q", extend["class"])
	}
	if extend["year"] != "2024" {
		t.Fatalf("init year want 2024, got %q", extend["year"])
	}
	// 已有值不被覆盖
	extend["year"] = "2026"
	mergeFilterDefaults(extend, filters)
	if extend["year"] != "2026" {
		t.Fatalf("existing extend must keep, got %q", extend["year"])
	}
}
