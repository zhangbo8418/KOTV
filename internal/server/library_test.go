package server

import "testing"

func TestSplitLibraryKey(t *testing.T) {
	cases := []struct {
		in, site, id string
	}{
		{"vod1@mysite", "mysite", "vod1"},
		{"mysite$$$vod1", "mysite", "vod1"},
		{"http://a/b@push_agent", "push_agent", "http://a/b"},
		{"onlyid", "", "onlyid"},
		{"", "", ""},
	}
	for _, c := range cases {
		site, id := splitLibraryKey(c.in)
		if site != c.site || id != c.id {
			t.Fatalf("%q → site=%q id=%q want %q %q", c.in, site, id, c.site, c.id)
		}
	}
}
