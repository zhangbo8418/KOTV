package playproxy_test

import (
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

func TestRawSpliceKeepsUpstreamBytes(t *testing.T) {
	t.Parallel()
	payload := bytesRepeat("0123456789abcdef", 4000)
	var gotRange, gotCookie, gotAE string
	up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotRange = r.Header.Get("Range")
		gotCookie = r.Header.Get("Cookie")
		gotAE = r.Header.Get("Accept-Encoding")
		w.Header().Set("Content-Type", "video/mp4")
		w.Header().Set("Accept-Ranges", "bytes")
		w.Header().Set("Content-Length", strconv.Itoa(len(payload)))
		_, _ = w.Write([]byte(payload))
	}))
	defer up.Close()

	proxyURL := playproxy.Register(up.URL+"/movie.mp4", map[string]string{"Cookie": "qk=1"})
	body, res := doSplice(t, proxyURL, "bytes=0-99")
	if res.StatusCode != http.StatusOK {
		t.Fatalf("status=%d", res.StatusCode)
	}
	if gotRange != "bytes=0-99" {
		t.Fatalf("range=%q", gotRange)
	}
	if gotCookie != "qk=1" {
		t.Fatalf("cookie=%q", gotCookie)
	}
	if strings.Contains(strings.ToLower(gotAE), "gzip") {
		t.Fatalf("Accept-Encoding=%q", gotAE)
	}
	if res.Header.Get("Content-Type") != "video/mp4" {
		t.Fatalf("type=%q", res.Header.Get("Content-Type"))
	}
	if res.Header.Get("Accept-Ranges") != "bytes" {
		t.Fatalf("Accept-Ranges=%q", res.Header.Get("Accept-Ranges"))
	}
	if res.Header.Get("Content-Length") != strconv.Itoa(len(payload)) {
		t.Fatalf("Content-Length=%q", res.Header.Get("Content-Length"))
	}
	if string(body) != payload {
		t.Fatalf("len=%d", len(body))
	}
}

func TestRawSpliceFollowsLoopbackRedirect(t *testing.T) {
	t.Parallel()
	const payload = "0123456789abcdef-redirected"
	final := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Cookie") != "qk=1" {
			http.Error(w, "no cookie", http.StatusForbidden)
			return
		}
		w.Header().Set("Content-Type", "video/mp4")
		w.Header().Set("Content-Length", strconv.Itoa(len(payload)))
		_, _ = w.Write([]byte(payload))
	}))
	defer final.Close()
	bounce := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, final.URL+"/file.mp4", http.StatusFound)
	}))
	defer bounce.Close()

	proxyURL := playproxy.Register(bounce.URL+"/start", map[string]string{"Cookie": "qk=1"})
	body, res := doSplice(t, proxyURL, "")
	if res.StatusCode != http.StatusOK {
		t.Fatalf("status=%d body=%q", res.StatusCode, body)
	}
	if string(body) != payload {
		t.Fatalf("body=%q", body)
	}
}

func TestRawSpliceRewritesLoopbackPlaylist(t *testing.T) {
	up := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/vnd.apple.mpegurl")
		_, _ = w.Write([]byte("#EXTM3U\n#EXTINF:1,\nseg.ts\n"))
	}))
	defer up.Close()

	proxyURL := playproxy.Register(up.URL+"/video", map[string]string{"Cookie": "qk=1"})
	u, err := url.Parse(proxyURL)
	if err != nil {
		t.Fatal(err)
	}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		done := hostclient.EnterSession("splice-playlist", "", false)
		defer done()
		hostclient.SetPublicBase("http://192.168.1.8:9978")
		playproxy.Handle(w, r)
	}))
	defer srv.Close()
	res, err := http.Get(srv.URL + u.RequestURI())
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	body, _ := io.ReadAll(res.Body)
	text := string(body)
	if res.StatusCode != http.StatusOK {
		t.Fatalf("status=%d body=%s", res.StatusCode, text)
	}
	if strings.Contains(text, up.URL) || strings.Contains(text, "127.0.0.1") {
		t.Fatalf("segment stayed on origin: %s", text)
	}
	if !strings.Contains(text, "http://192.168.1.8:9978/proxy/play?id=") {
		t.Fatalf("body=%s", text)
	}
	var media string
	for _, line := range strings.Split(text, "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		media = line
		break
	}
	upstream, headers := playproxy.Resolve(media)
	if upstream != up.URL+"/seg.ts" {
		t.Fatalf("segment upstream=%q", upstream)
	}
	if headers["Cookie"] != "qk=1" {
		t.Fatalf("segment headers=%v", headers)
	}
}

func TestRawSpliceDialError(t *testing.T) {
	t.Parallel()
	proxyURL := playproxy.Register("http://127.0.0.1:1/movie.mp4", map[string]string{"Cookie": "qk=1"})
	body, res := doSplice(t, proxyURL, "")
	if res.StatusCode != http.StatusBadGateway {
		t.Fatalf("status=%d body=%q", res.StatusCode, body)
	}
}

func doSplice(t *testing.T, proxyURL, rangeHdr string) ([]byte, *http.Response) {
	t.Helper()
	u, err := url.Parse(proxyURL)
	if err != nil {
		t.Fatal(err)
	}
	srv := httptest.NewServer(http.HandlerFunc(playproxy.Handle))
	t.Cleanup(srv.Close)
	req, err := http.NewRequest(http.MethodGet, srv.URL+u.RequestURI(), nil)
	if err != nil {
		t.Fatal(err)
	}
	if rangeHdr != "" {
		req.Header.Set("Range", rangeHdr)
	}
	res, err := http.DefaultClient.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { res.Body.Close() })
	body, err := io.ReadAll(res.Body)
	if err != nil {
		t.Fatal(err)
	}
	return body, res
}

func bytesRepeat(s string, n int) string {
	return strings.Repeat(s, n)
}
