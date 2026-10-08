package m3u8

import (
	"io"
	"net/http"
	"net/http/httptest"
	"strconv"
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

	got, direct, err := ResolveForPlayback(srv.URL+"/live.m3u8", nil, 9978)
	if err != nil {
		t.Fatal(err)
	}
	if direct != "" {
		t.Fatalf("no headers should not expose a second url, got %s", direct)
	}
	if got != srv.URL+"/live.m3u8" {
		t.Fatalf("sliding window must stay on the original url, got %s", got)
	}
}

func TestResolveForPlayback_MasterWithoutEndListUsesVariant(t *testing.T) {
	const master = "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1000\nmedia.m3u8\n"
	const media = "#EXTM3U\n#EXT-X-TARGETDURATION:7\n#EXTINF:6.000,\nseg0.ts\n#EXTINF:6.000,\nseg1.ts\n"
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if strings.HasSuffix(r.URL.Path, "/media.m3u8") {
			_, _ = io.WriteString(w, media)
			return
		}
		_, _ = io.WriteString(w, master)
	}))
	defer srv.Close()

	got, direct, err := ResolveForPlayback(srv.URL+"/live.m3u8", nil, 9978)
	if err != nil {
		t.Fatal(err)
	}
	if direct != "" {
		t.Fatalf("variant url is already playable, got direct %s", direct)
	}
	if got != srv.URL+"/media.m3u8" {
		t.Fatalf("want selected variant, got %s", got)
	}
}

func TestResolveForPlayback_HeadersRefetchRollingPlaylist(t *testing.T) {
	var n int
	const master = "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1000\nmedia.m3u8\n"
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Cookie") != "k=v" {
			t.Errorf("cookie missing on %s", r.URL.Path)
		}
		if strings.HasSuffix(r.URL.Path, "/media.m3u8") {
			n++
			_, _ = io.WriteString(w, "#EXTM3U\n#EXT-X-MEDIA-SEQUENCE:"+strconv.Itoa(n)+"\n#EXTINF:6.000,\nseg.ts\n#EXTINF:6.000,\nsegx.ts\n")
			return
		}
		_, _ = io.WriteString(w, master)
	}))
	defer srv.Close()

	hdr := map[string]string{"Cookie": "k=v", "Referer": "https://cdn.example/"}
	got, direct, err := ResolveForPlayback(srv.URL+"/live.m3u8", hdr, 9978)
	if err != nil {
		t.Fatal(err)
	}
	if direct != srv.URL+"/live.m3u8" {
		t.Fatalf("header-capable player should get the site url, got %s", direct)
	}
	if strings.Contains(got, "/proxy/cached_m3u8") || !strings.Contains(got, RollingPlaylistPath+"?id=") {
		t.Fatalf("want rolling playlist, got %s", got)
	}
	id := got[strings.LastIndex(got, "id=")+3:]
	first, ok := ServeRolling(id)
	if !ok || !strings.Contains(first, "/proxy/play?id=") || strings.Contains(first, "/seg.ts") {
		t.Fatalf("first refetch:\n%s", first)
	}
	if !strings.Contains(first, "#EXT-X-MEDIA-SEQUENCE:2") {
		t.Fatalf("first refetch should be a new pull, got:\n%s", first)
	}
	second, ok := ServeRolling(id)
	if !ok || !strings.Contains(second, "#EXT-X-MEDIA-SEQUENCE:3") {
		t.Fatalf("second refetch:\n%s", second)
	}
}

func TestResolveForPlayback_VodWithEndListCached(t *testing.T) {
	const body = "#EXTM3U\n#EXT-X-TARGETDURATION:4\n#EXTINF:4.000,\nseg0.ts\n#EXTINF:4.000,\nseg1.ts\n#EXT-X-ENDLIST\n"
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/vnd.apple.mpegurl")
		_, _ = io.WriteString(w, body)
	}))
	defer srv.Close()

	got, direct, err := ResolveForPlayback(srv.URL+"/vod.m3u8", nil, 9978)
	if err != nil {
		t.Fatal(err)
	}
	if direct != "" {
		t.Fatalf("filtered playlist should stay the only url, got direct %s", direct)
	}
	if !strings.Contains(got, "/proxy/cached_m3u8?id=") {
		t.Fatalf("vod playlist should be cached, got %s", got)
	}
}
