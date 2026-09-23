package source

import (
	"os"
	"path/filepath"
	"testing"
)

func TestPrepare_VideoAndPush(t *testing.T) {
	out, force, direct := Prepare("video://http://cdn/a.m3u8")
	if out != "http://cdn/a.m3u8" || !force || direct {
		t.Fatalf("video: out=%q force=%v direct=%v", out, force, direct)
	}
	out, force, direct = Prepare("push://http://cdn/b.mp4")
	if out != "http://cdn/b.mp4" || force || !direct {
		t.Fatalf("push: out=%q force=%v direct=%v", out, force, direct)
	}
	out, force, direct = Prepare("http://cdn/c.m3u8")
	if out != "http://cdn/c.m3u8" || force || direct {
		t.Fatalf("plain: out=%q force=%v direct=%v", out, force, direct)
	}
}

func TestPrepare_StrmFile(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, "chan.strm")
	if err := os.WriteFile(p, []byte("http://real/play.m3u8\n#comment\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	out, force, direct := Prepare(p)
	if out != "http://real/play.m3u8" || force || !direct {
		t.Fatalf("strm: out=%q force=%v direct=%v", out, force, direct)
	}
}
