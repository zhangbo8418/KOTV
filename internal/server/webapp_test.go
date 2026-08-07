package server

import (
	"os"
	"path/filepath"
	"testing"
)

func TestResolveWebappDir(t *testing.T) {
	dir := t.TempDir()
	web := filepath.Join(dir, "webapp")
	if err := os.MkdirAll(web, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(web, "index.html"), []byte("<html></html>"), 0o644); err != nil {
		t.Fatal(err)
	}
	t.Setenv("KOTV_WEBAPP", web)
	got := resolveWebappDir()
	if got != filepath.Clean(web) {
		t.Fatalf("got %q want %q", got, web)
	}
	t.Setenv("KOTV_WEBAPP", filepath.Join(dir, "missing"))
	// 无有效 KOTV_WEBAPP 时可能仍扫到其它路径；至少 missing 不应被当成有效
	if webappHasIndex(filepath.Join(dir, "missing")) {
		t.Fatal("missing should not have index")
	}
}
