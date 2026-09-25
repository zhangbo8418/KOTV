package spider

import (
	"strings"
	"testing"
)

func TestS2tUnlessClicker_NoClicker(t *testing.T) {
	in := "简体内容与专业"
	got := s2tUnlessClicker(in)
	want := s2t(in)
	if got != want {
		t.Fatalf("no clicker: got %q want %q", got, want)
	}
}

func TestS2tUnlessClicker_WithClicker(t *testing.T) {
	// label「专业」→「專業」；JSON type_name 保持简体不动。
	in := `前缀简体[a=cr:{"type_id":"1","type_name":"电影"}/]专业[/a]后缀专业`
	got := s2tUnlessClicker(in)
	want := `前綴簡體[a=cr:{"type_id":"1","type_name":"电影"}/]專業[/a]後綴專業`
	if got != want {
		t.Fatalf("with clicker:\n got %q\nwant %q", got, want)
	}
	if !strings.Contains(got, `"type_name":"电影"`) {
		t.Fatalf("json body mutated: %q", got)
	}
}

func TestS2tUnlessClicker_MultiClicker(t *testing.T) {
	in := `[a=cr:{"type_id":"a"}/]专业[/a]与[a=cr:{"type_id":"b"}/]简单[/a]`
	got := s2tUnlessClicker(in)
	want := `[a=cr:{"type_id":"a"}/]專業[/a]與[a=cr:{"type_id":"b"}/]簡單[/a]`
	if got != want {
		t.Fatalf("multi:\n got %q\nwant %q", got, want)
	}
}
