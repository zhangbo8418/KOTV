package m3u8

import (
	"io"
	"net/http"
	"net/http/httptest"
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

func TestResolveForPlayback_SlidingWindowNotCached(t *testing.T) {
	const body = "#EXTM3U\n#EXT-X-TARGETDURATION:7\n#EXT-X-MEDIA-SEQUENCE:10\n#EXTINF:6.000,\nseg0.ts\n#EXTINF:6.000,\nseg1.ts\n#EXTINF:5.640,\nseg2.ts\n"
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/vnd.apple.mpegurl")
		_, _ = io.WriteString(w, body)
	}))
	defer srv.Close()

	got, err := ResolveForPlayback(srv.URL+"/live.m3u8", nil, 9978)
	if err != nil {
		t.Fatal(err)
	}
	if got != srv.URL+"/live.m3u8" {
		t.Fatalf("sliding window must stay on the original url, got %s", got)
	}
}

func TestResolveForPlayback_VodWithEndListCached(t *testing.T) {
	const body = "#EXTM3U\n#EXT-X-TARGETDURATION:4\n#EXTINF:4.000,\nseg0.ts\n#EXTINF:4.000,\nseg1.ts\n#EXT-X-ENDLIST\n"
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/vnd.apple.mpegurl")
		_, _ = io.WriteString(w, body)
	}))
	defer srv.Close()

	got, err := ResolveForPlayback(srv.URL+"/vod.m3u8", nil, 9978)
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(got, "/proxy/cached_m3u8?id=") {
		t.Fatalf("vod playlist should be cached, got %s", got)
	}
}
