package grouppolicy

import (
	"testing"

	"github.com/bobo/KOTV/internal/database"
	"github.com/bobo/KOTV/internal/model"
)

func TestInjectLivesEmptyKeepsVodLives(t *testing.T) {
	api := &model.Api{Lives: model.LiveList{{Name: "卫视", URL: "http://live/a.m3u8"}}}
	b := Bundle{
		Caps:  map[string]bool{"allowLive": true},
		Lives: nil,
	}
	b.InjectLives(api)
	if len(api.Lives) != 1 || api.Lives[0].Name != "卫视" {
		t.Fatalf("empty group lives wiped vod lives: %+v", api.Lives)
	}
}

func TestInjectLivesGroupOverrides(t *testing.T) {
	api := &model.Api{Lives: model.LiveList{{Name: "卫视", URL: "http://live/a.m3u8"}}}
	b := Bundle{
		Caps: map[string]bool{"allowLive": true},
		Lives: []database.GroupLive{
			{Name: "组源", URL: "http://live/group.m3u8", Enabled: true},
		},
	}
	b.InjectLives(api)
	if len(api.Lives) != 1 || api.Lives[0].Name != "组源" || api.Lives[0].URL != "http://live/group.m3u8" {
		t.Fatalf("group lives = %+v", api.Lives)
	}
}

func TestInjectLivesDisallowClears(t *testing.T) {
	api := &model.Api{Lives: model.LiveList{{Name: "卫视", URL: "http://live/a.m3u8"}}}
	b := Bundle{Caps: map[string]bool{"allowLive": false}}
	b.InjectLives(api)
	if len(api.Lives) != 0 {
		t.Fatalf("disallow live should clear: %+v", api.Lives)
	}
}
