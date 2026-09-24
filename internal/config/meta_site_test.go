package config

import (
	"testing"

	"github.com/bobo/KOTV/internal/model"
)

func TestIsMetaSite_AutoDefaultOnly(t *testing.T) {
	cases := []struct {
		key, name string
		want      bool
	}{
		{"豆瓣", "豆瓣", true},
		{"TGDouban", "TG豆瓣", true},
		{"网盘配置", "网盘及彈幕配置", true},
		{"Youtube", "Youtube", false},
		{"Local", "本地", false},
		{"bili", "B站", false},
		{"切源", "点我切源", true},
	}
	for _, c := range cases {
		got := IsMetaSite(model.Site{Key: c.key, Name: c.name})
		if got != c.want {
			t.Fatalf("%s/%s: got %v want %v", c.key, c.name, got, c.want)
		}
	}
}

func TestPickDefaultHome_SkipsDoubanAndConfig(t *testing.T) {
	sites := []model.Site{
		{Key: "豆瓣", Name: "豆瓣"},
		{Key: "网盘配置", Name: "网盘及彈幕配置"},
		{Key: "Youtube", Name: "Youtube"},
	}
	home := PickDefaultHome(sites)
	if home.Key != "Youtube" {
		t.Fatalf("PickDefaultHome got %q want Youtube", home.Key)
	}
}
