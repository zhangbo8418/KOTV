package live

import (
	"testing"

	"github.com/bobo/KOTV/internal/config"
	"github.com/bobo/KOTV/internal/database"
	"github.com/bobo/KOTV/internal/settings"
)

func vodJSON(liveName, liveURL string) string {
	return `{"sites":[{"key":"k","name":"n","type":1,"api":"csp_X"}],"lives":[{"name":"` + liveName + `","url":"` + liveURL + `"}]}`
}

func parseVod(t *testing.T, m *config.Manager, url, liveName, liveURL string) {
	t.Helper()
	err := m.ParseConfig(&database.Config{
		URL:  url,
		Name: url,
		JSON: vodJSON(liveName, liveURL),
	}, true)
	if err != nil {
		t.Fatal(err)
	}
}

func TestSyncFromConfigUsesVodLives(t *testing.T) {
	prev := settings.Get(settings.LIVE)
	t.Cleanup(func() {
		settings.Set(settings.LIVE, prev)
		_ = settings.Save()
	})
	settings.Set(settings.LIVE, "")

	m := config.NewManager(nil)
	parseVod(t, m, "http://example.com/api.json", "卫视", "http://live/a.m3u8")
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

func TestSwitchVodFollowsEmbeddedLives(t *testing.T) {
	prev := settings.Get(settings.LIVE)
	t.Cleanup(func() {
		settings.Set(settings.LIVE, prev)
		_ = settings.Save()
	})
	settings.Set(settings.LIVE, "")

	m := config.NewManager(nil)
	parseVod(t, m, "http://a.example/api.json", "源A直播", "http://live/a.m3u8")
	parseVod(t, m, "http://b.example/api.json", "源B直播", "http://live/b.m3u8")
	if got := settings.Get(settings.LIVE); got != "http://b.example/api.json" {
		t.Fatalf("live pointer after switch = %q", got)
	}

	svc := NewService(m)
	svc.SyncFromConfig()
	srcs := svc.Sources()
	if len(srcs) != 1 || srcs[0].Name != "源B直播" || srcs[0].URL != "http://live/b.m3u8" {
		t.Fatalf("sources after switch = %+v", srcs)
	}
}

func TestSwitchVodKeepsCustomLive(t *testing.T) {
	prev := settings.Get(settings.LIVE)
	t.Cleanup(func() {
		settings.Set(settings.LIVE, prev)
		_ = settings.Save()
	})
	settings.Set(settings.LIVE, "")

	m := config.NewManager(nil)
	parseVod(t, m, "http://a.example/api.json", "源A直播", "http://live/a.m3u8")
	settings.Set(settings.LIVE, "http://custom/live.m3u")
	_ = settings.Save()
	parseVod(t, m, "http://b.example/api.json", "源B直播", "http://live/b.m3u8")
	if got := settings.Get(settings.LIVE); got != "http://custom/live.m3u" {
		t.Fatalf("custom live overwritten: %q", got)
	}

	svc := NewService(m)
	svc.SyncFromConfig()
	srcs := svc.Sources()
	if len(srcs) != 1 || srcs[0].URL != "http://custom/live.m3u" {
		t.Fatalf("sources = %+v", srcs)
	}
}
