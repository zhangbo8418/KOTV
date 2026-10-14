package app

import (
	"encoding/base64"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/bobo/KOTV/internal/hostclient"
	"github.com/bobo/KOTV/internal/playproxy"
)

func TestIsLocalMediaURL(t *testing.T) {
	t.Parallel()
	cases := []struct {
		u    string
		want bool
	}{
		{"file:///storage/emulated/0/Movies/a.mp4", true},
		{"file:///storage/emulated/0/Movies/中文.mkv", true},
		{"content://media/external/video/media/12", true},
		{"/storage/emulated/0/DCIM/Camera/a.mp4", true},
		{"/storage/emulated/0/Download/show.mkv", true},
		{"https://cdn.example.com/a.mp4", false},
		{"/api/v1/vod", false},
		{"", false},
	}
	for _, c := range cases {
		if got := IsLocalMediaURL(c.u); got != c.want {
			t.Fatalf("IsLocalMediaURL(%q)=%v want %v", c.u, got, c.want)
		}
	}
}

func TestApiLooksUnplayableLocal(t *testing.T) {
	t.Parallel()
	if apiLooksUnplayable("file:///storage/emulated/0/Movies/a.mp4") {
		t.Fatal("file:// mp4 should be playable")
	}
	if apiLooksUnplayable("/storage/emulated/0/Movies/a.mkv") {
		t.Fatal("absolute local mkv should be playable")
	}
	if apiLooksUnplayable("content://media/external/video/media/1") {
		t.Fatal("content:// should be playable")
	}
	if !apiLooksUnplayable("https://example.com/play.html") {
		t.Fatal("html page should be unplayable")
	}
	if !apiLooksUnplayable("") {
		t.Fatal("empty should be unplayable")
	}
}

func TestPreparePlaybackURLSkipsLocal(t *testing.T) {
	t.Parallel()
	a := &App{}
	in := "file:///storage/emulated/0/a.mp4"
	if got := a.PreparePlaybackURL(in, map[string]string{"User-Agent": "x"}); got != in {
		t.Fatalf("local url was proxied: %s", got)
	}
}

func TestPreparePlaybackURLLocalFileStaysPath(t *testing.T) {
	hostclient.SetPublicBase("")
	f, err := os.CreateTemp("", "kotv-local-*.mp4")
	if err != nil {
		t.Fatal(err)
	}
	name := f.Name()
	f.Close()
	defer os.Remove(name)
	a := &App{}
	if got := a.PreparePlaybackURL(name, nil); got != name {
		t.Fatalf("local playback changed path: %s", got)
	}
	if got := a.PreparePlaybackURL("content://media/1", nil); got != "content://media/1" {
		t.Fatalf("content uri changed: %s", got)
	}
}

func TestPreparePlaybackURLRemoteLocalFile(t *testing.T) {
	hostclient.SetPublicBase("http://203.0.113.8:9978")
	defer hostclient.SetPublicBase("")
	f, err := os.CreateTemp("", "kotv-remote-*.mp4")
	if err != nil {
		t.Fatal(err)
	}
	name := f.Name()
	f.Close()
	defer os.Remove(name)
	a := &App{}
	got := a.PreparePlaybackURL(name, nil)
	prefix := "http://203.0.113.8:9978/file/"
	if !strings.HasPrefix(got, prefix) {
		t.Fatalf("remote local file = %q", got)
	}
	if !strings.Contains(got, filepath.Base(name)) {
		t.Fatalf("remote local file missing name: %s", got)
	}
	if got := a.PreparePlaybackURL("content://media/1", nil); got != "content://media/1" {
		t.Fatalf("content uri changed: %s", got)
	}
	missing := "/tmp/kotv-missing-not-there.mp4"
	if got := a.PreparePlaybackURL(missing, nil); got != missing {
		t.Fatalf("missing file rewritten: %s", got)
	}
}

func TestPreparePlaybackURLLocalKeepsQuarkSpiderProxy(t *testing.T) {
	a := &App{}
	cdn := "https://cdn-quark.example/01.mkv"
	hdrJSON := `{"Cookie":"qk=1","User-Agent":"Quark"}`
	raw := "proxy://do=quark&type=video&url=" +
		base64.StdEncoding.EncodeToString([]byte(cdn)) +
		"&header=" + base64.StdEncoding.EncodeToString([]byte(hdrJSON))
	got := a.PreparePlaybackURL(raw, nil)
	if strings.Contains(got, "/proxy/play?id=") {
		t.Fatalf("local must keep /proxy for jar, got %q", got)
	}
	if !strings.Contains(got, "/proxy?") {
		t.Fatalf("local expected spider /proxy, got %q", got)
	}
}

func TestPreparePlaybackURLRemoteExpandsQuarkProxy(t *testing.T) {
	done := hostclient.EnterSession("test-client", "", false)
	defer done()
	hostclient.SetPublicBase("http://192.168.1.8:9978")

	a := &App{}
	cdn := "https://cdn-quark.example/01.mkv"
	hdrJSON := `{"Cookie":"qk=1","User-Agent":"Quark"}`
	raw := "proxy://do=quark&type=video&url=" +
		base64.StdEncoding.EncodeToString([]byte(cdn)) +
		"&header=" + base64.StdEncoding.EncodeToString([]byte(hdrJSON))
	got := a.PreparePlaybackURL(raw, nil)
	if !strings.Contains(got, "/proxy/play?id=") {
		t.Fatalf("remote default expected /proxy/play, got %q", got)
	}
	upstream, headers := playproxy.Resolve(got)
	if upstream != cdn {
		t.Fatalf("upstream=%q want %q", upstream, cdn)
	}
	if headers["Cookie"] != "qk=1" {
		t.Fatalf("headers=%v", headers)
	}
}

func TestPreparePlaybackURLRelaysOtherLoopbackPort(t *testing.T) {
	done := hostclient.EnterSession("relay-client", "", false)
	defer done()
	hostclient.SetPublicBase("http://192.168.1.8:9978")

	a := &App{}
	raw := "http://127.0.0.1:5266/fishplay/go/quark/32t/abc"
	got := a.PreparePlaybackURL(raw, nil)
	if !strings.Contains(got, "http://192.168.1.8:9978/proxy/play?id=") {
		t.Fatalf("other loopback port should be relayed, got %q", got)
	}
	upstream, _ := playproxy.Resolve(got)
	if upstream != raw {
		t.Fatalf("upstream=%q want %q", upstream, raw)
	}
}

func TestPreparePlaybackURLRemoteKeepsEnginePort(t *testing.T) {
	done := hostclient.EnterSession("engine-port", "", false)
	defer done()
	hostclient.SetPublicBase("http://192.168.1.8:9978")

	a := &App{}
	raw := "http://127.0.0.1:9978/file/a.jpg"
	got := a.PreparePlaybackURL(raw, nil)
	if strings.Contains(got, "/proxy/play?") {
		t.Fatalf("engine port must not be relayed, got %q", got)
	}
	if got != "http://192.168.1.8:9978/file/a.jpg" {
		t.Fatalf("got %q", got)
	}
}

func TestPreparePlaybackURLLocalKeepsOtherLoopbackPort(t *testing.T) {
	done := hostclient.EnterSession("local-side", "", false)
	defer done()
	hostclient.SetPublicBase("")

	a := &App{}
	raw := "http://127.0.0.1:5266/fishplay/go/quark/32t/abc"
	if got := a.PreparePlaybackURL(raw, nil); got != raw {
		t.Fatalf("local playback should keep %q, got %q", raw, got)
	}
}

func TestPreparePlaybackURLRemoteExpandsM3U8Proxy(t *testing.T) {
	done := hostclient.EnterSession("m3u8-proxy", "", false)
	defer done()
	hostclient.SetPublicBase("http://192.168.1.8:9978")

	a := &App{}
	cdn := "http://127.0.0.1:1/a.m3u8"
	hdrJSON := `{"Cookie":"qk=1"}`
	raw := "proxy://do=quark&type=video&url=" +
		base64.StdEncoding.EncodeToString([]byte(cdn)) +
		"&header=" + base64.StdEncoding.EncodeToString([]byte(hdrJSON))
	got := a.PreparePlaybackURL(raw, nil)
	if !strings.Contains(got, "/proxy/play?id=") {
		t.Fatalf("remote m3u8 proxy should be /proxy/play, got %q", got)
	}
	upstream, headers := playproxy.Resolve(got)
	if upstream != cdn {
		t.Fatalf("upstream=%q want %q", upstream, cdn)
	}
	if headers["Cookie"] != "qk=1" {
		t.Fatalf("headers=%v", headers)
	}
}

func TestPreparePlaybackDirectKeepsPublicURL(t *testing.T) {
	a := &App{}
	raw := "https://cdn.example/a.mp4"
	play, direct := a.PreparePlayback(raw, map[string]string{"Cookie": "a=b"})
	if !strings.Contains(play, "/proxy/play?id=") {
		t.Fatalf("other players still use proxy, got %q", play)
	}
	if direct != raw {
		t.Fatalf("direct=%q want %q", direct, raw)
	}
}

func TestPreparePlaybackDirectSkipsLoopback(t *testing.T) {
	a := &App{}
	raw := "http://127.0.0.1:5266/a.mp4"
	_, direct := a.PreparePlayback(raw, map[string]string{"Cookie": "a=b"})
	if direct != "" {
		t.Fatalf("loopback must not be opened by the player, got %q", direct)
	}
}

// 直播 Load/livePlay 与点播共用 PreparePlayback：无头则 url=原址、direct 空。
func TestPreparePlaybackLivePlainURL(t *testing.T) {
	a := &App{}
	raw := "https://cdn.example/live.m3u8"
	play, direct := a.PreparePlayback(raw, nil)
	if play != raw {
		t.Fatalf("play=%q want %q", play, raw)
	}
	if direct != "" {
		t.Fatalf("direct=%q want empty", direct)
	}
}

// 列表路径不得去拉含 m3u8 的直播地址（广告过滤默认开时 Resolve 会 HTTP）。
func TestPreparePlaybackListedSkipsM3U8Resolve(t *testing.T) {
	a := &App{}
	raw := "https://tv.bobohome.store:20250/migu?id=608807420.m3u8"
	start := time.Now()
	play, direct := a.PreparePlaybackListed(raw, nil)
	if dur := time.Since(start); dur > 200*time.Millisecond {
		t.Fatalf("listed prepare too slow: %s (must not Resolve)", dur)
	}
	if play != raw {
		t.Fatalf("play=%q want %q", play, raw)
	}
	if direct != "" {
		t.Fatalf("direct=%q want empty", direct)
	}
}
