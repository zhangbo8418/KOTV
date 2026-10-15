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
		Key: "v1@s1", VodName: "剧", RevSort: 1, Opening: 3000, Ending: 5000, Position: 100, Duration: 1000,
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
	if got.Opening != 3000 || got.Ending != 5000 {
		t.Fatalf("offsets opening=%d ending=%d", got.Opening, got.Ending)
	}

	list, err := db.ListHistory("", 10)
	if err != nil {
		t.Fatal(err)
	}
	if len(list) != 1 || list[0].RevSort != 1 {
		t.Fatalf("ListHistory=%+v", list)
	}
}
