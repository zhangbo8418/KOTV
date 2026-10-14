package database

import "testing"

func TestNormalizeExternalHistoryKey(t *testing.T) {
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
		got := NormalizeExternalHistoryKey(c.in)
		if got != c.want {
			t.Fatalf("NormalizeExternalHistoryKey(%q)=%q want %q", c.in, got, c.want)
		}
	}
}

func TestExternalHistoryKey(t *testing.T) {
	if got := ExternalHistoryKey("vod1@site"); got != "site$$$vod1" {
		t.Fatalf("got %q", got)
	}
}
