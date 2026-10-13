package parse

import "testing"

func TestPickPlayHeadersKeepsTokenDropsHopByHop(t *testing.T) {
	in := map[string]string{
		"User-Agent":        "UA/1",
		"Cookie":            "a=b",
		"Authorization":     "Bearer tok",
		"Token":             "site-token",
		"X-Token":           "x",
		"Referer":           "https://ref.example/",
		"Origin":            "https://o.example",
		"Range":             "bytes=0-",
		"Host":              "cdn.example",
		"Connection":        "keep-alive",
		"Content-Length":    "1",
		"Transfer-Encoding": "chunked",
		"Accept-Encoding":   "gzip",
		" ":                 "skip-empty-key",
		"Empty":             "  ",
	}
	got := pickPlayHeaders(in)
	wantKeep := []string{"User-Agent", "Cookie", "Authorization", "Token", "X-Token", "Referer", "Origin"}
	for _, k := range wantKeep {
		if got[k] != in[k] {
			t.Fatalf("%s: got %q want %q (map=%v)", k, got[k], in[k], got)
		}
	}
	wantDrop := []string{"Range", "Host", "Connection", "Content-Length", "Transfer-Encoding", "Accept-Encoding", " ", "Empty"}
	for _, k := range wantDrop {
		if _, ok := got[k]; ok {
			t.Fatalf("should drop %q, got map=%v", k, got)
		}
	}
	if pickPlayHeaders(nil) != nil {
		t.Fatal("nil in → nil out")
	}
	if pickPlayHeaders(map[string]string{"Range": "bytes=0-"}) != nil {
		t.Fatal("only hop-by-hop → nil out")
	}
}
