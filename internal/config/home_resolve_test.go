package config

import (
	"testing"

	"github.com/bobo/KOTV/internal/model"
)

func TestPickDefaultHome_FirstVisible(t *testing.T) {
	sites := []model.Site{
		{Key: "豆瓣", Name: "豆瓣"},
		{Key: "网盘配置", Name: "网盘及彈幕配置"},
		{Key: "Youtube", Name: "Youtube"},
	}
	home := PickDefaultHome(sites)
	if home.Key != "豆瓣" {
		t.Fatalf("PickDefaultHome got %q want 豆瓣", home.Key)
	}
}

func TestResolveHome_PrefersSavedKey(t *testing.T) {
	sites := []model.Site{
		{Key: "豆瓣", Name: "豆瓣"},
		{Key: "Youtube", Name: "Youtube"},
	}
	home := resolveHome("Youtube", sites)
	if home.Key != "Youtube" {
		t.Fatalf("resolveHome got %q want Youtube", home.Key)
	}
	missing := resolveHome("gone", sites)
	if missing.Key != "" {
		t.Fatalf("missing key should be empty, got %q", missing.Key)
	}
}
