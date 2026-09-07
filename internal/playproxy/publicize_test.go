package playproxy

import (
	"strings"
	"testing"

	"github.com/bobo/KOTV/internal/hostclient"
)

func TestPublicizeURLRewritesPrivateAndLoopback(t *testing.T) {
	done := hostclient.EnterSession("pub-test", "", false)
	defer done()
	hostclient.SetPublicBase("https://tv.example.com")

	cases := []struct {
		in   string
		want string
	}{
		{"http://127.0.0.1:9978/proxy/play?id=a", "https://tv.example.com/proxy/play?id=a"},
		{"http://192.168.1.8:9978/proxy?do=quark", "https://tv.example.com/proxy?do=quark"},
		{"http://10.0.0.2:9978/proxy/play?id=1", "https://tv.example.com/proxy/play?id=1"},
		{"https://cdn.example/a.m3u8", "https://cdn.example/a.m3u8"},
		{"https://tv.example.com/proxy/play?id=z", "https://tv.example.com/proxy/play?id=z"},
	}
	for _, c := range cases {
		got := PublicizeURL(c.in)
		if got != c.want {
			t.Fatalf("PublicizeURL(%q)=%q want %q", c.in, got, c.want)
		}
	}
	if !strings.HasPrefix(PublicizeURL("http://tv.example.com/proxy/x"), "https://") {
		t.Fatal("same host should unify scheme to https")
	}
}
