package util

import (
	"net/url"
	"os"
	"path/filepath"
	"testing"
)

func TestFileURLPathAndHTTPGet(t *testing.T) {
	dir := t.TempDir()
	name := filepath.Join(dir, "八戒影视.py")
	if err := os.WriteFile(name, []byte("# ok"), 0o644); err != nil {
		t.Fatal(err)
	}

	raw := (&url.URL{Scheme: "file", Path: filepath.ToSlash(name)}).String()
	got, ok := FileURLPath(raw)
	if !ok {
		t.Fatalf("FileURLPath(%q) false", raw)
	}
	if filepath.Clean(got) != filepath.Clean(name) {
		t.Fatalf("path=%q want=%q (raw=%q)", got, name, raw)
	}

	text, err := HTTPGet(raw, nil)
	if err != nil {
		t.Fatal(err)
	}
	if text != "# ok" {
		t.Fatalf("got %q", text)
	}

	// 百分号编码中文路径（与报错里的 URL 一致）
	escaped := "file://" + filepath.ToSlash(dir) + "/" + url.PathEscape("八戒影视.py")
	text, err = HTTPGet(escaped, nil)
	if err != nil {
		t.Fatalf("escaped HTTPGet: %v (%s)", err, escaped)
	}
	if text != "# ok" {
		t.Fatalf("escaped got %q", text)
	}
}
