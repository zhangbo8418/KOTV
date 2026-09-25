package config

import (
	"path/filepath"
	"testing"

	"github.com/bobo/KOTV/internal/database"
	"github.com/bobo/KOTV/internal/model"
)

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

func TestResolveHome_IncludesHidden(t *testing.T) {
	sites := []model.Site{
		{Key: "cfg", Name: "配置", Hide: model.FlexInt{Valid: true, Value: 1}},
		{Key: "豆瓣", Name: "豆瓣"},
	}
	home := resolveHome("cfg", sites)
	if home.Key != "cfg" {
		t.Fatalf("resolveHome on full list got %q want cfg", home.Key)
	}
}

func TestLoadFromSource_RuntimeHomeUsesFullList(t *testing.T) {
	m := NewManager(nil)
	// hide 站排第一：可见列表只有豆瓣，全量 resolve 应落在 cfg。
	raw := `{"sites":[{"key":"cfg","name":"配置","hide":1,"type":3,"api":"csp_Config"},{"key":"豆瓣","name":"豆瓣","type":1,"api":"http://example.test"}]}`
	if err := m.LoadFromSource(raw); err != nil {
		t.Fatalf("LoadFromSource: %v", err)
	}
	if got := m.Home().Key; got != "cfg" {
		t.Fatalf("Home()=%q want cfg (first of full sites)", got)
	}
	if len(m.Sites()) != 1 || m.Sites()[0].Key != "豆瓣" {
		t.Fatalf("Sites() should be visible-only, got %+v", m.Sites())
	}
}

func TestLoadFromSource_FallbackHomeNotPersisted(t *testing.T) {
	db, err := database.OpenPath(filepath.Join(t.TempDir(), "home.db"))
	if err != nil {
		t.Fatalf("OpenPath: %v", err)
	}
	defer db.Close()

	const url = "file:///tmp/kotv-home-resolve-test.json"
	id, err := db.UpsertConfig(&database.Config{
		Type: database.ConfigTypeSite,
		URL:  url,
		Home: "gone",
		JSON: `{"sites":[{"key":"豆瓣","name":"豆瓣","type":1,"api":"http://example.test"},{"key":"Youtube","name":"Youtube","type":1,"api":"http://example.test/y"}]}`,
	})
	if err != nil || id == 0 {
		t.Fatalf("seed UpsertConfig: id=%d err=%v", id, err)
	}

	m := NewManager(db)
	if err := m.ParseConfig(&database.Config{
		ID:   id,
		Type: database.ConfigTypeSite,
		URL:  url,
		Home: "gone",
		JSON: `{"sites":[{"key":"豆瓣","name":"豆瓣","type":1,"api":"http://example.test"},{"key":"Youtube","name":"Youtube","type":1,"api":"http://example.test/y"}]}`,
	}, true); err != nil {
		t.Fatalf("ParseConfig: %v", err)
	}
	if got := m.Home().Key; got != "豆瓣" {
		t.Fatalf("runtime Home()=%q want 豆瓣", got)
	}
	got, err := db.FindConfig(url, database.ConfigTypeSite)
	if err != nil || got == nil {
		t.Fatalf("FindConfig: %v", err)
	}
	if got.Home != "gone" {
		t.Fatalf("DB home persisted fallback=%q want gone (unchanged)", got.Home)
	}
}

func TestSetHome_PersistsExplicitChoice(t *testing.T) {
	db, err := database.OpenPath(filepath.Join(t.TempDir(), "sethome.db"))
	if err != nil {
		t.Fatalf("OpenPath: %v", err)
	}
	defer db.Close()

	const url = "file:///tmp/kotv-sethome-test.json"
	raw := `{"sites":[{"key":"豆瓣","name":"豆瓣","type":1,"api":"http://example.test"},{"key":"Youtube","name":"Youtube","type":1,"api":"http://example.test/y"}]}`
	m := NewManager(db)
	if err := m.ParseConfig(&database.Config{
		Type: database.ConfigTypeSite,
		URL:  url,
		JSON: raw,
	}, true); err != nil {
		t.Fatalf("ParseConfig: %v", err)
	}
	m.SetHome(model.Site{Key: "Youtube", Name: "Youtube"})
	got, err := db.FindConfig(url, database.ConfigTypeSite)
	if err != nil || got == nil {
		t.Fatalf("FindConfig: %v", err)
	}
	if got.Home != "Youtube" {
		t.Fatalf("explicit SetHome DB home=%q want Youtube", got.Home)
	}
}
