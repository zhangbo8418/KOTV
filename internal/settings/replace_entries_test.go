package settings

import (
	"path/filepath"
	"testing"

	"github.com/bobo/KOTV/internal/database"
)

func TestReplaceEntriesForOwnerClearsMissingKeys(t *testing.T) {
	db, err := database.OpenPath(filepath.Join(t.TempDir(), "set.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	BindDB(db)
	t.Cleanup(func() { BindDB(nil) })

	if err := db.SetSetting("u1", "vod", "old-vod"); err != nil {
		t.Fatal(err)
	}
	if err := db.SetSetting("u1", "home", "old-home"); err != nil {
		t.Fatal(err)
	}
	if err := db.SetSetting("u1", "theme", "dark"); err != nil {
		t.Fatal(err)
	}

	ReplaceEntriesForOwner("u1", []Entry{
		{ID: "vod", Value: "new-vod"},
		{ID: "home", Value: "new-home"},
	})

	v, ok, err := db.GetSetting("u1", "vod")
	if err != nil || !ok || v != "new-vod" {
		t.Fatalf("vod=%q ok=%v err=%v", v, ok, err)
	}
	v, ok, err = db.GetSetting("u1", "home")
	if err != nil || !ok || v != "new-home" {
		t.Fatalf("home=%q ok=%v err=%v", v, ok, err)
	}
	if _, ok, _ = db.GetSetting("u1", "theme"); ok {
		t.Fatal("theme should be cleared by replace")
	}
}

func TestReplaceEntriesForOwnerSkipsHostOnlyForRemote(t *testing.T) {
	db, err := database.OpenPath(filepath.Join(t.TempDir(), "set2.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	BindDB(db)
	t.Cleanup(func() { BindDB(nil) })

	if err := db.SetSetting("", "deviceUUID", "host-uuid"); err != nil {
		t.Fatal(err)
	}
	ReplaceEntriesForOwner("u2", []Entry{
		{ID: "vod", Value: "u2-vod"},
		{ID: "deviceUUID", Value: "stolen"},
	})
	v, ok, err := db.GetSetting("u2", "vod")
	if err != nil || !ok || v != "u2-vod" {
		t.Fatalf("vod=%q ok=%v err=%v", v, ok, err)
	}
	if _, ok, _ = db.GetSetting("u2", "deviceUUID"); ok {
		t.Fatal("remote owner must not receive host-only keys")
	}
	v, ok, err = db.GetSetting("", "deviceUUID")
	if err != nil || !ok || v != "host-uuid" {
		t.Fatalf("host deviceUUID=%q ok=%v err=%v", v, ok, err)
	}
}
