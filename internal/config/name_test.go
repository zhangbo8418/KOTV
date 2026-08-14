package config

import "testing"

func TestConfigLabelSingleRepoUsesFullURL(t *testing.T) {
	u := "https://example.com/path/api.json"
	if got := ConfigLabel("", u); got != u {
		t.Fatalf("empty name = %q", got)
	}
	if got := ConfigLabel("api.json", u); got != u {
		t.Fatalf("legacy tail name = %q", got)
	}
	if got := ConfigLabel("饭太硬", u); got != "饭太硬" {
		t.Fatalf("depot name = %q", got)
	}
}

func TestSourceDisplayNameIsFullURL(t *testing.T) {
	u := "https://example.com/path/api.json"
	if got := SourceDisplayName(u); got != u {
		t.Fatalf("got %q", got)
	}
}
