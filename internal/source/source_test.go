package source

import "testing"

func TestMatchYouTubeAndForce(t *testing.T) {
	cases := map[string]bool{
		"https://www.youtube.com/watch?v=dQw4w9WgXcQ": true,
		"https://youtu.be/dQw4w9WgXcQ":                 true,
		"p2p://example.com:8080/chan":                 true,
		"mitv://example.com/x":                        true,
		"jianpian://id/1":                             true,
		"tvbus://x":                                   true,
		"https://example.com/a.m3u8":                  false,
		"": false,
	}
	for u, want := range cases {
		if got := Match(u); got != want {
			t.Fatalf("Match(%q)=%v want %v", u, got, want)
		}
	}
}
