package parse

import "testing"

func TestNestedFollowKey(t *testing.T) {
	a := "https://cdn.example/entry.php?host=x&vid=ABC&t=play"
	b := "https://cdn.example/player/?type=play&vid=ABC&referer=x"
	if nestedFollowKey(a) != nestedFollowKey(b) {
		t.Fatalf("want same key, got %q vs %q", nestedFollowKey(a), nestedFollowKey(b))
	}
	c := "https://cdn.example/player/?vid=OTHER"
	if nestedFollowKey(a) == nestedFollowKey(c) {
		t.Fatalf("different vid should differ")
	}
}

func TestSniffPlayAPIResult(t *testing.T) {
	play, _, note := sniffPlayAPIResult(`{"code":404,"msg":"error"}`)
	if play != "" || note == "" {
		t.Fatalf("want empty play + note, got play=%q note=%q", play, note)
	}
	play, _, note = sniffPlayAPIResult(`{"code":200,"msg":"ok","url":"https://cdn.example/video/tos/x"}`)
	if note != "" || play == "" {
		t.Fatalf("want play, got play=%q note=%q", play, note)
	}
	play, _, note = sniffPlayAPIResult(`{"url":"https://cdn.example/a.m3u8"}`)
	if note != "" || play == "" {
		t.Fatalf("want url without code, got play=%q note=%q", play, note)
	}
}
