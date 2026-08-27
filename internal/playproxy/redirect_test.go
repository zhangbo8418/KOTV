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
	if res.StatusCode != 200 || string(body) != "MP4" {
		t.Fatalf("status=%d body=%s", res.StatusCode, body)
	}
}
