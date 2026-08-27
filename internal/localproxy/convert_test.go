package localproxy

import "testing"

func TestConvertSchemeProxy(t *testing.T) {
	t.Parallel()
	SetPort(9978)
	got := ConvertScheme("proxy://do=quark&type=video&url=abc")
	want := "http://127.0.0.1:9978/proxy?do=quark&type=video&url=abc"
	if got != want {
		t.Fatalf("got %q want %q", got, want)
	}
}

func TestIsSpiderProxyURL(t *testing.T) {
	t.Parallel()
	cases := []struct {
		u    string
		want bool
	}{
		{"proxy://do=quark&url=x", true},
		{"http://127.0.0.1:9978/proxy?do=quark&url=x", true},
		{"http://192.168.1.8:9978/proxy?do=uc&type=video", true},
		{"http://127.0.0.1:9978/proxy/play?id=1", false},
		{"http://127.0.0.1:9978/proxy/cached_m3u8?id=1", false},
		{"https://cdn.example/a.mkv", false},
	}
	for _, c := range cases {
		if got := IsSpiderProxyURL(c.u); got != c.want {
			t.Fatalf("IsSpiderProxyURL(%q)=%v want %v", c.u, got, c.want)
		}
	}
}
