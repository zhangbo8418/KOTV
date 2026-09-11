package hlsproxy

import (
	"net/http"
	"strings"
	"testing"
)

func TestRewritePlaylistMapsSegmentsAndAttributes(t *testing.T) {
	in := `#EXTM3U
#EXT-X-VERSION:3
#EXT-X-KEY:METHOD=AES-128,URI="key.key"
#EXTINF:4.0,
seg0.ts
#EXT-X-STREAM-INF:BANDWIDTH=800000
variant.m3u8
`
	out := rewritePlaylist(in, "https://cdn.example/live/index.m3u8", func(abs string) string {
		return "http://127.0.0.1/proxy/hls/item?u=" + abs
	})
	if !strings.Contains(out, `URI="http://127.0.0.1/proxy/hls/item?u=https://cdn.example/live/key.key"`) {
		t.Fatalf("key not rewritten: %s", out)
	}
	if !strings.Contains(out, "http://127.0.0.1/proxy/hls/item?u=https://cdn.example/live/seg0.ts") {
		t.Fatalf("segment not rewritten: %s", out)
	}
	if !strings.Contains(out, "http://127.0.0.1/proxy/hls/item?u=https://cdn.example/live/variant.m3u8") {
		t.Fatalf("variant not rewritten: %s", out)
	}
}

func TestShouldOpenWithoutHeaders(t *testing.T) {
	u := "https://cdn.example/a.m3u8"
	if !ShouldOpen(u, "", nil) {
		t.Fatal("hls url should proxy without headers")
	}
	if !ShouldOpen("https://cdn.example/live/index", "application/x-mpegURL", nil) {
		t.Fatal("format hint should proxy")
	}
	if ShouldOpen("https://cdn.example/a.mp4", "", map[string]string{"Referer": "https://x.example/"}) {
		t.Fatal("non-hls should not proxy")
	}
	if LikelyHLS("https://tv.example/fengshows?id=1.m3u8", "") {
		t.Fatal("query-only m3u8 must not look like HLS")
	}
}

func TestStableTargetID(t *testing.T) {
	a := stableTargetID("https://cdn.example/a.ts")
	b := stableTargetID("https://cdn.example/a.ts")
	c := stableTargetID("https://cdn.example/b.ts")
	if a == "" || a != b {
		t.Fatalf("stable id mismatch %q %q", a, b)
	}
	if a == c {
		t.Fatal("different urls must differ")
	}
}

func TestStripDisguisePrefix(t *testing.T) {
	png := []byte{0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a}
	ts := make([]byte, 188*3)
	for i := 0; i < 3; i++ {
		ts[i*188] = 0x47
	}
	in := append(png, ts...)
	out := StripDisguisePrefix(in)
	if out[0] != 0x47 {
		t.Fatalf("expected ts sync, got %#x", out[0])
	}
}

func TestPublicBaseFromRequest(t *testing.T) {
	r, _ := http.NewRequest(http.MethodGet, "http://ignored/proxy/hls/index.m3u8", nil)
	r.Host = "192.168.1.8:9978"
	if got := publicBaseFromRequest(r); got != "http://192.168.1.8:9978" {
		t.Fatalf("got %q", got)
	}
	r.Host = "127.0.0.1:9978"
	if got := publicBaseFromRequest(r); got != "" {
		t.Fatalf("loopback should empty, got %q", got)
	}
	r.Host = "tv.example.com"
	r.Header.Set("X-Forwarded-Proto", "https")
	if got := publicBaseFromRequest(r); got != "https://tv.example.com" {
		t.Fatalf("got %q", got)
	}
}
