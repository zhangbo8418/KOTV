package database

import (
	"path/filepath"
	"testing"
)

func TestSettingOwnerBuckets(t *testing.T) {
	db, err := OpenPath(filepath.Join(t.TempDir(), "set.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()

	if err := db.SetSetting("", "vod", "http://host/a.json"); err != nil {
		t.Fatal(err)
	}
	if err := db.SetSetting("u1", "vod", "http://u1/b.json"); err != nil {
		t.Fatal(err)
	}
	v, ok, err := db.GetSetting("", "vod")
	if err != nil || !ok || v != "http://host/a.json" {
		t.Fatalf("host vod=%q ok=%v err=%v", v, ok, err)
	}
	v, ok, err = db.GetSetting("u1", "vod")
	if err != nil || !ok || v != "http://u1/b.json" {
		t.Fatalf("u1 vod=%q ok=%v err=%v", v, ok, err)
	}
	if err := db.DeleteSettingsOwner("u1"); err != nil {
		t.Fatal(err)
	}
	if _, ok, _ = db.GetSetting("u1", "vod"); ok {
		t.Fatal("u1 setting should be gone")
	}
	if _, ok, _ = db.GetSetting("", "vod"); !ok {
		t.Fatal("host setting must remain")
	}
}

func TestDeleteSettingsOwnerClearsHost(t *testing.T) {
	db, err := OpenPath(filepath.Join(t.TempDir(), "set-host.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	if err := db.SetSetting("", "vod", "a"); err != nil {
		t.Fatal(err)
	}
	if err := db.SetSetting("", "home", "s1"); err != nil {
		t.Fatal(err)
	}
	if err := db.DeleteSettingsOwner(""); err != nil {
		t.Fatal(err)
	}
	if _, ok, _ := db.GetSetting("", "vod"); ok {
		t.Fatal("host vod should be cleared")
	}
	if _, ok, _ := db.GetSetting("", "home"); ok {
		t.Fatal("host home should be cleared")
	}
}

func TestAuthUserAndToken(t *testing.T) {
	db, err := OpenPath(filepath.Join(t.TempDir(), "auth.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()

	u := AuthUser{ID: "1", Username: "admin", PassHash: "x", Role: "admin", Enabled: true}
	if err := db.UpsertAuthUser(u); err != nil {
		t.Fatal(err)
	}
	got, err := db.GetAuthUserByName("Admin")
	if err != nil || got == nil || got.ID != "1" {
		t.Fatalf("GetAuthUserByName: %+v err=%v", got, err)
	}
	n, err := db.CountAuthAdmins()
	if err != nil || n != 1 {
		t.Fatalf("admins=%d err=%v", n, err)
	}
}
