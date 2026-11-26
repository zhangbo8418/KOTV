package spider

import (
	"strings"
	"testing"
)

func TestConvertSearchKeywordByLang(t *testing.T) {
	if got := ConvertSearchKeyword("电影", "zh-TW"); got != "電影" {
		t.Fatalf("zh-TW: got %q", got)
	}
	if got := ConvertSearchKeyword("電影", "zh-CN"); got != "电影" {
		t.Fatalf("zh-CN: got %q", got)
	}
	if got := ConvertSearchKeyword("電影", "zh-Hans"); got != "电影" {
		t.Fatalf("zh-Hans: got %q", got)
	}
	if got := ConvertSearchKeyword("电影", "zh-Hant"); got != "電影" {
		t.Fatalf("zh-Hant: got %q", got)
	}
	if got := ConvertSearchKeyword("電影", "en"); got != "電影" {
		t.Fatalf("other lang should keep text: got %q", got)
	}
	if got := ConvertSearchKeyword("", "zh-CN"); got != "" {
		t.Fatalf("empty: got %q", got)
	}
}

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
