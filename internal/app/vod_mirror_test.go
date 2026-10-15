package app

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/bobo/KOTV/internal/clientsession"
	"github.com/bobo/KOTV/internal/settings"
)

func TestMirrorLocalSelectedVod_WritesSettingsForClientScope(t *testing.T) {
	root := t.TempDir()
	t.Setenv("KOTV_DATA_DIR", root)
	prev := settings.Get(settings.VOD)
	t.Cleanup(func() { settings.Set(settings.VOD, prev) })

	const want = "https://example.test/vod-new.json"
	settings.Set(settings.VOD, "https://example.test/vod-old.json")

	mirrorLocalSelectedVod(&clientsession.Session{ClientID: "c:test-client"}, want)
	if got := settings.Get(settings.VOD); got != want {
		t.Fatalf("settings.VOD=%q want %q", got, want)
	}
	b, err := os.ReadFile(filepath.Join(root, "setting.ini"))
	if err != nil {
		t.Fatalf("read setting.ini: %v", err)
	}
	if !strings.Contains(string(b), want) {
		t.Fatalf("setting.ini missing %q: %s", want, string(b))
	}
}

func TestMirrorLocalSelectedVod_SkipsUserScope(t *testing.T) {
	prev := settings.Get(settings.VOD)
	t.Cleanup(func() { settings.Set(settings.VOD, prev) })

	const keep = "https://example.test/host.json"
	settings.Set(settings.VOD, keep)
	mirrorLocalSelectedVod(&clientsession.Session{ClientID: "u:42"}, "https://example.test/tenant.json")
	if got := settings.Get(settings.VOD); got != keep {
		t.Fatalf("tenant session stomped host VOD: got %q want %q", got, keep)
	}
}
