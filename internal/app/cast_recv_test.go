package app

import "testing"

func TestNormalizeHistoryKey(t *testing.T) {
	cases := []struct {
		in, want string
	}{
		{"site$$$vod1", "vod1@site"},
		{"site@@@vod1@@@0", "vod1@site"},
		{"push_agent@@@http://a/b@@@0", "http://a/b@push_agent"},
		{"already@site", "already@site"},
		{"", ""},
	}
	for _, c := range cases {
		got := normalizeHistoryKey(c.in)
		if got != c.want {
			t.Fatalf("normalizeHistoryKey(%q)=%q want %q", c.in, got, c.want)
		}
	}
}
