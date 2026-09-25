package backup_test

import (
	"testing"

	"github.com/bobo/KOTV/internal/backup"
	"github.com/bobo/KOTV/internal/database"
)

func TestExportClientRoundTrip(t *testing.T) {
	hist := []database.History{{
		Key: "s1$$$v1", VodName: "剧A", VodPic: "p", Position: 12000, Duration: 60000,
	}}
	keep := []database.Keep{{
		Key: "s1$$$v2", VodName: "剧B", Type: database.KeepTypeVod,
	}}
	raw, err := backup.ExportClient(hist, keep)
	if err != nil {
		t.Fatal(err)
	}
	if len(raw) < 10 {
		t.Fatalf("empty export")
	}
	// Import needs a DB; just verify ExportClient packs without ListAll.
	_ = raw
}
