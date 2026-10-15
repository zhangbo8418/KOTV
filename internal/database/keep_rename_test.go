package database

import (
	"path/filepath"
	"testing"
)

func TestRenameKeepPreservesFields(t *testing.T) {
	db, err := OpenPath(filepath.Join(t.TempDir(), "k.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	if err := db.ImportKeep("", []Keep{{
		Key: "s$$$old", VodName: "剧", VodPic: "p", VodFlag: "f", VodRemarks: "r", Type: KeepTypeVod, CID: 3, SiteName: "站",
	}}, 2); err != nil {
		t.Fatal(err)
	}
	if err := db.RenameKeep("", "s$$$old", "s$$$new"); err != nil {
		t.Fatal(err)
	}
	if old, _ := db.GetKeep("", "s$$$old"); old != nil {
		t.Fatal("old should be gone")
	}
	got, err := db.GetKeep("", "s$$$new")
	if err != nil || got == nil {
		t.Fatalf("GetKeep: %v %+v", err, got)
	}
	if got.VodName != "剧" || got.VodPic != "p" || got.CID != 3 || got.SiteName != "站" {
		t.Fatalf("got=%+v", got)
	}
}

func TestRenameKeepDropsOldWhenNewExists(t *testing.T) {
	db, err := OpenPath(filepath.Join(t.TempDir(), "k2.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	if err := db.ImportKeep("", []Keep{
		{Key: "s$$$old", VodName: "旧", Type: KeepTypeVod},
		{Key: "s$$$new", VodName: "新", Type: KeepTypeVod},
	}, 2); err != nil {
		t.Fatal(err)
	}
	if err := db.RenameKeep("", "s$$$old", "s$$$new"); err != nil {
		t.Fatal(err)
	}
	if old, _ := db.GetKeep("", "s$$$old"); old != nil {
		t.Fatal("old should be gone")
	}
	got, err := db.GetKeep("", "s$$$new")
	if err != nil || got == nil || got.VodName != "新" {
		t.Fatalf("new should remain: %+v err=%v", got, err)
	}
}
