package database

import (
	"path/filepath"
	"testing"
)

func TestImportHistoryPreservesRevSort(t *testing.T) {
	dir := t.TempDir()
	db, err := OpenPath(filepath.Join(dir, "t.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()

	if err := db.ImportHistory("", []History{{
		Key: "v1@s1", VodName: "剧", RevSort: 1, RevPlay: 900, Opening: 3000, Ending: 5000, Position: 100, Duration: 1000,
	}}, 2); err != nil {
		t.Fatal(err)
	}

	got, err := db.GetHistory("", "v1@s1")
	if err != nil || got == nil {
		t.Fatalf("GetHistory: %v %+v", err, got)
	}
	if got.RevSort != 1 {
		t.Fatalf("RevSort=%d want 1", got.RevSort)
	}
	if got.RevPlay != 900 {
		t.Fatalf("RevPlay=%d want 900", got.RevPlay)
	}
	if got.Opening != 3000 || got.Ending != 5000 {
		t.Fatalf("offsets opening=%d ending=%d", got.Opening, got.Ending)
	}

	list, err := db.ListHistory("", 10)
	if err != nil {
		t.Fatal(err)
	}
	if len(list) != 1 || list[0].RevSort != 1 || list[0].RevPlay != 900 {
		t.Fatalf("ListHistory=%+v", list)
	}
}

func TestImportHistoryOrdersByRevPlay(t *testing.T) {
	dir := t.TempDir()
	db, err := OpenPath(filepath.Join(dir, "t.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()

	if err := db.ImportHistory("", []History{
		{Key: "old@s", VodName: "旧", RevPlay: 100},
		{Key: "new@s", VodName: "新", RevPlay: 200},
	}, 2); err != nil {
		t.Fatal(err)
	}
	list, err := db.ListHistory("", 10)
	if err != nil {
		t.Fatal(err)
	}
	if len(list) != 2 || list[0].Key != "new@s" || list[1].Key != "old@s" {
		t.Fatalf("order=%+v", list)
	}
}

func TestRenameHistoryPreservesFields(t *testing.T) {
	dir := t.TempDir()
	db, err := OpenPath(filepath.Join(dir, "t.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()
	if err := db.ImportHistory("", []History{{
		Key: "old@s", VodName: "剧", RevSort: 1, RevPlay: 77, Opening: 11, Ending: 22, Position: 33, Duration: 44,
	}}, 2); err != nil {
		t.Fatal(err)
	}
	if err := db.RenameHistory("", "old@s", "new@s"); err != nil {
		t.Fatal(err)
	}
	old, _ := db.GetHistory("", "old@s")
	if old != nil {
		t.Fatalf("old still exists")
	}
	got, err := db.GetHistory("", "new@s")
	if err != nil || got == nil {
		t.Fatalf("GetHistory: %v %+v", err, got)
	}
	if got.RevSort != 1 || got.RevPlay != 77 || got.Opening != 11 || got.Ending != 22 {
		t.Fatalf("got=%+v", got)
	}
}
