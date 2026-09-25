package config

import (
	"path/filepath"
	"testing"
	"time"

	"github.com/bobo/KOTV/internal/database"
	"github.com/bobo/KOTV/internal/settings"
)

func TestInitFromSettings_PrefersSettingsVODOverNewerDBRow(t *testing.T) {
	db, err := database.OpenPath(filepath.Join(t.TempDir(), "vod-pointer.db"))
	if err != nil {
		t.Fatalf("OpenPath: %v", err)
	}
	defer db.Close()

	const (
		keepURL = "file:///tmp/kotv-keep-pg.json"
		newURL  = "file:///tmp/kotv-newer-youtube.json"
	)
	keepJSON := `{"sites":[{"key":"cfg","name":"网盘及弹幕配置","hide":1,"type":3,"api":"csp_Config"},{"key":"豆瓣","name":"豆瓣","type":1,"api":"http://example.test"}]}`
	newJSON := `{"sites":[{"key":"Youtube","name":"Youtube","type":1,"api":"http://example.test/y"}]}`

	if _, err := db.UpsertConfig(&database.Config{
		Type: database.ConfigTypeSite, URL: keepURL, JSON: keepJSON, Name: "PG", Home: "cfg",
	}); err != nil {
		t.Fatalf("seed keep: %v", err)
	}
	time.Sleep(5 * time.Millisecond)
	if _, err := db.UpsertConfig(&database.Config{
		Type: database.ConfigTypeSite, URL: newURL, JSON: newJSON, Name: "Youtube仓",
	}); err != nil {
		t.Fatalf("seed newer: %v", err)
	}

	prev := settings.Get(settings.VOD)
	t.Cleanup(func() { settings.Set(settings.VOD, prev) })
	settings.Set(settings.VOD, keepURL)

	m := NewManager(db)
	m.EnsureVodFromHistory()
	if got := settings.Get(settings.VOD); got != keepURL {
		t.Fatalf("EnsureVodFromHistory stomped VOD: got %q want %q", got, keepURL)
	}
	if err := m.InitFromSettings(); err != nil {
		t.Fatalf("InitFromSettings: %v", err)
	}
	if got := m.API().URL; got != keepURL {
		t.Fatalf("loaded URL=%q want %q (settings.VOD, not newest DB row)", got, keepURL)
	}
	if got := m.Home().Key; got != "cfg" {
		t.Fatalf("Home=%q want cfg from persisted config.home", got)
	}
}
