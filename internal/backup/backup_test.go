package backup_test

import (
	"path/filepath"
	"testing"

	"github.com/bobo/KOTV/internal/backup"
	"github.com/bobo/KOTV/internal/database"
)

func TestExportImportRoundTrip(t *testing.T) {
	dir := t.TempDir()
	db, err := database.OpenPath(filepath.Join(dir, "t.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()

	if err := db.ImportHistory("", []database.History{{
		Key: "v1@s1", VodName: "剧A", RevSort: 1, Opening: 1000, Ending: 2000, Position: 12, Duration: 60,
	}}, 2); err != nil {
		t.Fatal(err)
	}
	if err := db.ImportKeep("", []database.Keep{{
		Key: "s1$$$v2", VodName: "剧B", Type: database.KeepTypeVod,
	}}, 2); err != nil {
		t.Fatal(err)
	}

	raw, err := backup.Export(db)
	if err != nil {
		t.Fatal(err)
	}
	if len(raw) < 10 {
		t.Fatalf("empty export")
	}

	db2, err := database.OpenPath(filepath.Join(dir, "t2.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer db2.Close()
	if _, err := backup.Import(db2, raw); err != nil {
		t.Fatal(err)
	}
	h, err := db2.GetHistory("", "v1@s1")
	if err != nil || h == nil {
		t.Fatalf("GetHistory: %v %+v", err, h)
	}
	if h.RevSort != 1 || h.Opening != 1000 || h.Ending != 2000 {
		t.Fatalf("history=%+v", h)
	}
	keeps, err := db2.ListAllKeep("", database.KeepTypeVod)
	if err != nil || len(keeps) != 1 || keeps[0].VodName != "剧B" {
		t.Fatalf("keep=%+v err=%v", keeps, err)
	}
}
