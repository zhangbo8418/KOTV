package playproxy_test

import (
	"encoding/base64"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
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
	if res.Header.Get("Accept-Ranges") != "bytes" {
		t.Fatalf("Accept-Ranges=%q", res.Header.Get("Accept-Ranges"))
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
