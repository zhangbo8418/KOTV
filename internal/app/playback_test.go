package app

import (
	"encoding/base64"
	"strings"
	"testing"

	"github.com/bobo/KOTV/internal/hostclient"
	"github.com/bobo/KOTV/internal/playproxy"
	"github.com/bobo/KOTV/internal/settings"
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

func TestPreparePlaybackURLLocalKeepsSpiderProxyLikeTV(t *testing.T) {
	// 本机无 PublicBase：保留 /proxy，不展开成 /proxy/play。
	a := &App{}
	cdn := "https://cdn-quark.example/01.mkv"
	hdrJSON := `{"Cookie":"qk=1","User-Agent":"Quark"}`
	raw := "proxy://do=quark&type=video&url=" +
		base64.StdEncoding.EncodeToString([]byte(cdn)) +
		"&header=" + base64.StdEncoding.EncodeToString([]byte(hdrJSON))
	got := a.PreparePlaybackURL(raw, nil)
	if !strings.Contains(got, "/proxy?") || strings.Contains(got, "/proxy/play?") {
		t.Fatalf("local should keep spider /proxy, got %q", got)
	}
}

func TestPreparePlaybackURLRemoteExpandsQuarkProxy(t *testing.T) {
	done := hostclient.EnterSession("test-client", "", false)
	defer done()
	hostclient.SetPublicBase("http://192.168.1.8:9978")
	settings.Set(settings.BackendProxyPlay, "false")
	defer settings.Set(settings.BackendProxyPlay, "false")

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

func TestPreparePlaybackURLRemoteBackendProxyKeepsSpider(t *testing.T) {
	done := hostclient.EnterSession("test-client-2", "", false)
	defer done()
	hostclient.SetPublicBase("http://192.168.1.8:9978")
	settings.Set(settings.BackendProxyPlay, "true")
	defer settings.Set(settings.BackendProxyPlay, "false")

	a := &App{}
	cdn := "https://cdn-quark.example/01.mkv"
	hdrJSON := `{"Cookie":"qk=1"}`
	raw := "proxy://do=quark&type=video&url=" +
		base64.StdEncoding.EncodeToString([]byte(cdn)) +
		"&header=" + base64.StdEncoding.EncodeToString([]byte(hdrJSON))
	got := a.PreparePlaybackURL(raw, nil)
	if !strings.Contains(got, "/proxy?") || strings.Contains(got, "/proxy/play?") {
		t.Fatalf("remote+backendProxy should keep spider /proxy, got %q", got)
	}
	if !strings.Contains(got, "192.168.1.8") {
		t.Fatalf("should publicize to LAN, got %q", got)
	}
}
