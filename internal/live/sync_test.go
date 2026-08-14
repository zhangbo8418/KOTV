package live

import (
	"testing"

	"github.com/bobo/KOTV/internal/config"
	"github.com/bobo/KOTV/internal/database"
	"github.com/bobo/KOTV/internal/settings"
)

func TestSyncFromConfigUsesVodLives(t *testing.T) {
	prev := settings.Get(settings.LIVE)
	t.Cleanup(func() {
		settings.Set(settings.LIVE, prev)
		_ = settings.Save()
	})
	settings.Set(settings.LIVE, "")

	m := config.NewManager(nil)
	err := m.ParseConfig(&database.Config{
		URL:  "http://example.com/api.json",
		Name: "demo",
		JSON: `{"sites":[{"key":"k","name":"n","type":1,"api":"csp_X"}],"lives":[{"name":"卫视","url":"http://live/a.m3u8"}]}`,
	}, true)
	if err != nil {
		t.Fatal(err)
	}
	if got := settings.Get(settings.LIVE); got != "http://example.com/api.json" {
		t.Fatalf("live pointer = %q", got)
	}

	svc := NewService(m)
	svc.SyncFromConfig()
	srcs := svc.Sources()
	if len(srcs) != 1 || srcs[0].Name != "卫视" {
		t.Fatalf("sources = %+v", srcs)
	}
}
