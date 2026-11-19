package cacheclean

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/bobo/KOTV/internal/paths"
)

func TestLogPathRejectsTraversal(t *testing.T) {
	dir := paths.LogDir()
	_ = os.MkdirAll(dir, 0o755)
	for _, name := range []string{"", ".", "..", "../x", "a/../b", "sub/x.log"} {
		if _, err := logPath(name); err == nil {
			t.Fatalf("expected reject %q", name)
		}
	}
	p, err := logPath("kotv.log")
	if err != nil {
		t.Fatal(err)
	}
	if filepath.Dir(p) != filepath.Clean(dir) {
		t.Fatalf("dir=%q path=%q", dir, p)
	}
}

func TestClearAndReadLogTail(t *testing.T) {
	dir := paths.LogDir()
	_ = os.MkdirAll(dir, 0o755)
	name := "kotv-test-admin.log"
	p := filepath.Join(dir, name)
	payload := []byte("hello-log-line\nsecond\n")
	if err := os.WriteFile(p, payload, 0o644); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Remove(p) })

	text, size, err := ReadLogTail(name, 64)
	if err != nil {
		t.Fatal(err)
	}
	if size != int64(len(payload)) || text == "" {
		t.Fatalf("size=%d text=%q", size, text)
	}
	freed, err := ClearLogFile(name)
	if err != nil {
		t.Fatal(err)
	}
	if freed <= 0 {
		t.Fatalf("freed=%d", freed)
	}
	st, err := os.Stat(p)
	if err != nil {
		t.Fatal(err)
	}
	if st.Size() != 0 {
		t.Fatalf("expected truncated, size=%d", st.Size())
	}
}
