package service

import (
	"os"
	"path/filepath"
	"testing"
)

func TestLocalDirCategory(t *testing.T) {
	t.Parallel()
	dir := t.TempDir()
	if err := os.Mkdir(filepath.Join(dir, "子目录"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "a.mp4"), []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "readme.txt"), []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	res, ok := localDirCategory(dir)
	if !ok {
		t.Fatal("expected ok")
	}
	if len(res.List) != 2 {
		t.Fatalf("list len=%d want 2 (folder+mp4)", len(res.List))
	}
	if res.List[0].VodTag != "folder" {
		t.Fatalf("first tag=%q want folder", res.List[0].VodTag)
	}
	if res.List[1].VodTag != "file" {
		t.Fatalf("second tag=%q want file", res.List[1].VodTag)
	}
}
