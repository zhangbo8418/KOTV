package database

import (
	"path/filepath"
	"testing"
)

func TestHistoryOwnerIsolation(t *testing.T) {
	dir := t.TempDir()
	db, err := OpenPath(filepath.Join(dir, "t.db"))
	if err != nil {
		t.Fatal(err)
	}
	defer db.Close()

	if err := db.SaveHistory("u1", History{Key: "a@s", VodName: "A1", Position: 1}); err != nil {
		t.Fatal(err)
	}
	if err := db.SaveHistory("u2", History{Key: "a@s", VodName: "A2", Position: 2}); err != nil {
		t.Fatal(err)
	}
	if err := db.SaveHistory("", History{Key: "local@s", VodName: "L"}); err != nil {
		t.Fatal(err)
	}

	u1, err := db.ListAllHistory("u1")
	if err != nil {
		t.Fatal(err)
	}
	if len(u1) != 1 || u1[0].VodName != "A1" {
		t.Fatalf("u1=%+v", u1)
	}
	u2, err := db.ListAllHistory("u2")
	if err != nil {
		t.Fatal(err)
	}
	if len(u2) != 1 || u2[0].VodName != "A2" {
		t.Fatalf("u2=%+v", u2)
	}
	local, err := db.ListAllHistory("")
	if err != nil {
		t.Fatal(err)
	}
	if len(local) != 1 || local[0].Key != "local@s" {
		t.Fatalf("local=%+v", local)
	}

	if err := db.ImportHistory("u1", []History{{Key: "b@s", VodName: "B"}}, 2); err != nil {
		t.Fatal(err)
	}
	u1, _ = db.ListAllHistory("u1")
	if len(u1) != 1 || u1[0].Key != "b@s" {
		t.Fatalf("after replace u1=%+v", u1)
	}
	u2, _ = db.ListAllHistory("u2")
	if len(u2) != 1 || u2[0].VodName != "A2" {
		t.Fatalf("u2 should be untouched: %+v", u2)
	}
}
