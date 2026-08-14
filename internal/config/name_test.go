package config

import "testing"

func TestConfigLabelNameOrFullURL(t *testing.T) {
	u := "https://tv.example.com/🐷PY/"
	if got := ConfigLabel("", u); got != u {
		t.Fatalf("empty name = %q", got)
	}
	// 多仓名字经常等于路径末段，必须原样显示，不能当成「无名字」。
	if got := ConfigLabel("🐷PY", u); got != "🐷PY" {
		t.Fatalf("depot name = %q", got)
	}
	if got := ConfigLabel("短剧.json", "https://d.example.com/download/8344/短剧.json"); got != "短剧.json" {
		t.Fatalf("file-like name = %q", got)
	}
}

func TestSourceDisplayNameIsFullURL(t *testing.T) {
	u := "https://example.com/path/api.json"
	if got := SourceDisplayName(u); got != u {
		t.Fatalf("got %q", got)
	}
}
