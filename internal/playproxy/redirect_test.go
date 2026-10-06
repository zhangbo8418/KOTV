package playproxy_test

import (
	"encoding/base64"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strconv"
	"strings"
	"testing"

	"github.com/bobo/KOTV/internal/hostclient"
	"github.com/bobo/KOTV/internal/playproxy"
)

func TestHandleKeepsCookieAcrossRedirect(t *testing.T) {
	t.Parallel()
	var sawCookie bool
	final := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if c := r.Header.Get("Cookie"); strings.Contains(c, "qk=1") {
			sawCookie = true
		}
		w.Header().Set("Content-Type", "video/x-matroska")
		_, _ = w.Write([]byte("MKVDATA"))
	}))
	defer final.Close()

	bounce := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, final.URL+"/file.mkv", http.StatusFound)
	}))
	defer bounce.Close()

	proxyURL := playproxy.Register(bounce.URL+"/start", map[string]string{
		"Cookie":     "qk=1",
		"User-Agent": "QuarkTest",
	})
	req := httptest.NewRequest(http.MethodGet, proxyURL, nil)
	rr := httptest.NewRecorder()
	playproxy.Handle(rr, req)
	res := rr.Result()
	defer res.Body.Close()
	body, _ := io.ReadAll(res.Body)
	if res.StatusCode != 200 {
		t.Fatalf("status=%d body=%s", res.StatusCode, body)
	}
	if !sawCookie {
		t.Fatal("cookie was stripped on redirect")
	}
	if string(body) != "MKVDATA" {
		t.Fatalf("body=%q", body)
	}
}

func TestTryHandleEmbeddedProxy(t *testing.T) {
	t.Parallel()
	final := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Cookie") != "qk=1" {
			http.Error(w, "no cookie", http.StatusForbidden)
			return
		}
		w.Header().Set("Content-Type", "video/mp4")
		_, _ = w.Write([]byte("MP4"))
	}))
	defer final.Close()

	hdr, _ := json.Marshal(map[string]string{"Cookie": "qk=1"})
	q := url.Values{}
	q.Set("do", "quark")
	q.Set("type", "video")
	q.Set("url", base64.StdEncoding.EncodeToString([]byte(final.URL+"/a.mp4")))
	q.Set("header", base64.StdEncoding.EncodeToString(hdr))
	req := httptest.NewRequest(http.MethodGet, "/proxy?"+q.Encode(), nil)
	rr := httptest.NewRecorder()
	if !playproxy.TryHandleEmbeddedProxy(rr, req) {
		t.Fatal("expected handle")
	}
	res := rr.Result()
	defer res.Body.Close()
	body, _ := io.ReadAll(res.Body)
	if res.Header.Get("Accept-Ranges") != "" {
		t.Fatalf("loopback file must not invent Accept-Ranges, got %q", res.Header.Get("Accept-Ranges"))
	}
	if res.StatusCode != 200 || string(body) != "MP4" {
		t.Fatalf("status=%d body=%s", res.StatusCode, body)
	}
}

func TestHandleTwoRanges(t *testing.T) {
	t.Parallel()
	var got []string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		got = append(got, r.Header.Get("Range"))
		w.Header().Set("Content-Type", "video/mp4")
		w.Header().Set("Accept-Ranges", "bytes")
		switch r.Header.Get("Range") {
		case "bytes=0-3":
			w.Header().Set("Content-Range", "bytes 0-3/8")
			w.WriteHeader(http.StatusPartialContent)
			_, _ = w.Write([]byte("abcd"))
		case "bytes=4-7":
			w.Header().Set("Content-Range", "bytes 4-7/8")
			w.WriteHeader(http.StatusPartialContent)
			_, _ = w.Write([]byte("efgh"))
		default:
			http.Error(w, "range", http.StatusBadRequest)
		}
	}))
	defer srv.Close()

	proxyURL := playproxy.Register(srv.URL+"/movie.mp4", map[string]string{"Cookie": "qk=1"})
	for _, rg := range []string{"bytes=0-3", "bytes=4-7"} {
		req := httptest.NewRequest(http.MethodGet, proxyURL, nil)
		req.Header.Set("Range", rg)
		rr := httptest.NewRecorder()
		playproxy.Handle(rr, req)
		res := rr.Result()
		body, _ := io.ReadAll(res.Body)
		res.Body.Close()
		if res.StatusCode != http.StatusPartialContent {
			t.Fatalf("range %s status=%d body=%s", rg, res.StatusCode, body)
		}
		if res.Header.Get("Accept-Ranges") != "bytes" {
			t.Fatalf("Accept-Ranges=%q", res.Header.Get("Accept-Ranges"))
		}
	}
	if len(got) != 2 || got[0] != "bytes=0-3" || got[1] != "bytes=4-7" {
		t.Fatalf("upstream ranges=%v", got)
	}
}

func TestHandlePassthroughKeepsStatusHeadersAndBody(t *testing.T) {
	t.Parallel()
	const payload = "\x00\x00\x00\x18ftypmp42BODY"
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Range") != "bytes=0-" {
			t.Errorf("range=%q", r.Header.Get("Range"))
		}
		w.Header().Set("Content-Type", "video/mp4")
		w.Header().Set("X-Play-State", "buffering")
		w.Header().Set("Content-Length", strconv.Itoa(len(payload)))
		w.WriteHeader(http.StatusPartialContent)
		_, _ = w.Write([]byte(payload))
	}))
	defer srv.Close()

	proxyURL := playproxy.Register(srv.URL+"/movie.mp4", map[string]string{"Cookie": "qk=1"})
	req := httptest.NewRequest(http.MethodGet, proxyURL, nil)
	req.Header.Set("Range", "bytes=0-")
	rr := httptest.NewRecorder()
	playproxy.Handle(rr, req)
	res := rr.Result()
	defer res.Body.Close()
	body, _ := io.ReadAll(res.Body)
	if res.StatusCode != http.StatusPartialContent {
		t.Fatalf("status=%d", res.StatusCode)
	}
	if res.Header.Get("X-Play-State") != "buffering" {
		t.Fatalf("state=%q", res.Header.Get("X-Play-State"))
	}
	if res.Header.Get("Accept-Ranges") != "" {
		t.Fatalf("invented Accept-Ranges=%q", res.Header.Get("Accept-Ranges"))
	}
	if res.Header.Get("Content-Type") != "video/mp4" {
		t.Fatalf("type=%q", res.Header.Get("Content-Type"))
	}
	if string(body) != payload {
		t.Fatalf("body=%q", body)
	}
}

func TestHandleForwardsGzipBodyWithoutRequestingIt(t *testing.T) {
	t.Parallel()
	payload := []byte{0x1f, 0x8b, 0x08, 0x00, 'b', 'o', 'd', 'y'}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if enc := r.Header.Get("Accept-Encoding"); strings.Contains(strings.ToLower(enc), "gzip") {
			t.Errorf("Accept-Encoding=%q", enc)
		}
		w.Header().Set("Content-Type", "video/mp4")
		w.Header().Set("Content-Encoding", "gzip")
		w.Header().Set("Content-Length", strconv.Itoa(len(payload)))
		_, _ = w.Write(payload)
	}))
	defer srv.Close()

	proxyURL := playproxy.Register(srv.URL+"/movie.mp4", map[string]string{"Cookie": "qk=1"})
	req := httptest.NewRequest(http.MethodGet, proxyURL, nil)
	rr := httptest.NewRecorder()
	playproxy.Handle(rr, req)
	res := rr.Result()
	defer res.Body.Close()
	body, _ := io.ReadAll(res.Body)
	if res.StatusCode != http.StatusOK {
		t.Fatalf("status=%d body=%q", res.StatusCode, body)
	}
	if res.Header.Get("Content-Encoding") != "gzip" {
		t.Fatalf("Content-Encoding=%q", res.Header.Get("Content-Encoding"))
	}
	if res.Header.Get("Content-Length") != strconv.Itoa(len(payload)) {
		t.Fatalf("Content-Length=%q", res.Header.Get("Content-Length"))
	}
	if string(body) != string(payload) {
		t.Fatalf("body=%q", body)
	}
}

func TestHandleLeavesCDNPlaylistBytes(t *testing.T) {
	t.Parallel()
	raw := "#EXTM3U\nhttps://cdn.example/a.ts\n"
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/vnd.apple.mpegurl")
		w.Header().Set("X-Play-State", "open")
		_, _ = w.Write([]byte(raw))
	}))
	defer srv.Close()

	proxyURL := playproxy.Register(srv.URL+"/v.m3u8", map[string]string{"Cookie": "qk=1"})
	req := httptest.NewRequest(http.MethodGet, proxyURL, nil)
	rr := httptest.NewRecorder()
	playproxy.Handle(rr, req)
	res := rr.Result()
	defer res.Body.Close()
	body, _ := io.ReadAll(res.Body)
	if res.StatusCode != 200 {
		t.Fatalf("status=%d", res.StatusCode)
	}
	if string(body) != raw {
		t.Fatalf("body=%q", body)
	}
	if res.Header.Get("X-Play-State") != "open" {
		t.Fatalf("state=%q", res.Header.Get("X-Play-State"))
	}
	if res.Header.Get("Accept-Ranges") != "" {
		t.Fatalf("invented Accept-Ranges=%q", res.Header.Get("Accept-Ranges"))
	}
}

func TestHandleRewritesPlaylistWithoutM3U8InURL(t *testing.T) {
	done := hostclient.EnterSession("playlist-rewrite", "", false)
	defer done()
	hostclient.SetPublicBase("http://192.168.1.8:9978")

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/octet-stream")
		_, _ = w.Write([]byte("#EXTM3U\n#EXTINF:1,\nseg.ts\n#EXT-X-KEY:METHOD=AES-128,URI=\"key\"\n"))
	}))
	defer srv.Close()

	proxyURL := playproxy.Register(srv.URL+"/video", map[string]string{"Cookie": "qk=1"})
	req := httptest.NewRequest(http.MethodGet, proxyURL, nil)
	rr := httptest.NewRecorder()
	playproxy.Handle(rr, req)
	res := rr.Result()
	defer res.Body.Close()
	body, _ := io.ReadAll(res.Body)
	text := string(body)
	if res.StatusCode != 200 {
		t.Fatalf("status=%d body=%s", res.StatusCode, text)
	}
	if strings.Contains(text, "127.0.0.1") || strings.Contains(text, srv.URL) {
		t.Fatalf("segment stayed on origin: %s", text)
	}
	if !strings.Contains(text, "http://192.168.1.8:9978/proxy/play?id=") {
		t.Fatalf("body=%s", text)
	}
	lines := strings.Split(text, "\n")
	var media string
	for _, line := range lines {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		media = line
		break
	}
	upstream, headers := playproxy.Resolve(media)
	if upstream != srv.URL+"/seg.ts" {
		t.Fatalf("segment upstream=%q", upstream)
	}
	if headers["Cookie"] != "qk=1" {
		t.Fatalf("segment headers=%v", headers)
	}
	if !strings.Contains(text, `URI="http://192.168.1.8:9978/proxy/play?id=`) {
		t.Fatalf("key uri not rewritten: %s", text)
	}
}
