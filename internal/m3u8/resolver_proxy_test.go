package m3u8

import (
	"strings"
	"testing"
)

func TestProxyMediaURIs_RewritesSegments(t *testing.T) {
	in := "#EXTM3U\n#EXTINF:4,\nhttps://cdn.example/a.ts\n#EXTINF:4,\nhttps://cdn.example/b.ts\n"
	hdr := map[string]string{"Cookie": "k=v", "Referer": "https://cdn.example/"}
	out := proxyMediaURIs(in, hdr)
	if strings.Contains(out, "cdn.example/a.ts") {
		t.Fatalf("segment should be proxied, got:\n%s", out)
	}
	if !strings.Contains(out, "/proxy/play?id=") {
		t.Fatalf("expected /proxy/play, got:\n%s", out)
	}
	if n := strings.Count(out, "/proxy/play?id="); n != 2 {
		t.Fatalf("want 2 proxied segments, got %d:\n%s", n, out)
	}
}

func TestProxyMediaURIs_NoHeadersKeepsCDN(t *testing.T) {
	in := "#EXTM3U\nhttps://cdn.example/a.ts\n"
	out := proxyMediaURIs(in, nil)
	if out != in {
		t.Fatalf("no headers should keep original")
	}
}

func TestProxyMediaURIs_RewritesTagURI(t *testing.T) {
	in := `#EXTM3U
#EXT-X-KEY:METHOD=AES-128,URI="https://cdn.example/key.bin"
https://cdn.example/a.ts
`
	hdr := map[string]string{"Cookie": "k=v"}
	out := proxyMediaURIs(in, hdr)
	if strings.Contains(out, `URI="https://cdn.example/key.bin"`) {
		t.Fatalf("key URI should be proxied, got:\n%s", out)
	}
	if !strings.Contains(out, `URI="`) || !strings.Contains(out, "/proxy/play?id=") {
		t.Fatalf("expected proxied URI, got:\n%s", out)
	}
}
