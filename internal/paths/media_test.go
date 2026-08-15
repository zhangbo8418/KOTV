package paths

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestResolveMediaPathRestoresLostLeadingSlash(t *testing.T) {
	dir := t.TempDir()
	f := filepath.Join(dir, "api.json")
	if err := os.WriteFile(f, []byte(`{}`), 0o644); err != nil {
		t.Fatal(err)
	}
	// 模拟 /file/ 代理丢掉前导 /：/tmp/x/api.json → tmp/x/api.json
	rel := strings.TrimPrefix(f, string(os.PathSeparator))
	if rel == f {
		t.Skip("temp path has no leading separator")
	}
	got := ResolveMediaPath(rel)
	if got != f {
		t.Fatalf("ResolveMediaPath(%q)=%q want %q", rel, got, f)
	}
}

func TestResolveMediaPathAbsolute(t *testing.T) {
	dir := t.TempDir()
	f := filepath.Join(dir, "cfg.json")
	if err := os.WriteFile(f, []byte(`{}`), 0o644); err != nil {
		t.Fatal(err)
	}
	got := ResolveMediaPath(f)
	if got != f {
		t.Fatalf("got %q want %q", got, f)
	}
}
