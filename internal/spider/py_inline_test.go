package spider

import (
	"os"
	"testing"
)

func TestIsInlinePySource(t *testing.T) {
	yes := []string{
		"# spider.py\nimport sys\nclass Spider: pass\n",
		"from base.spider import Spider\nclass Spider(Spider): pass",
		"import json",
	}
	for _, s := range yes {
		if !isInlinePySource(s) {
			t.Fatalf("want inline: %q", s)
		}
	}
	no := []string{
		"http://x/a.py",
		"https://x/a.py?x=1",
		"file:///tmp/a.py",
		"/abs/path/a.py",
		"a.py",
		"",
	}
	for _, s := range no {
		if isInlinePySource(s) {
			t.Fatalf("want not inline: %q", s)
		}
	}
}

func TestPyEnsureScript_InlineSourceWritten(t *testing.T) {
	src := "# demo.py\nfrom base.spider import Spider\nclass Spider(Spider):\n    pass\n"
	s := &pySpider{key: "k", api: src}
	path, err := s.ensureScript()
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Remove(path) })
	got, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if string(got) != src {
		t.Fatalf("written source mismatch:\n%s", got)
	}
	if s.scriptPath != path {
		t.Fatalf("scriptPath not cached")
	}
}
