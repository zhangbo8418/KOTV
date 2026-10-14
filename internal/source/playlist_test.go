package source

import (
	"testing"

	"github.com/bobo/KOTV/internal/model"
)

func TestMatchPlaylist(t *testing.T) {
	cases := map[string]bool{
		"https://www.youtube.com/playlist?list=PLxxx":                 true,
		"https://www.youtube.com/watch?v=abc&list=PLxxx":              true,
		"https://youtu.be/abc?list=PLxxx":                             true,
		"https://www.youtube.com/watch?v=abc":                         false,
		"https://example.com/playlist?list=1":                         false,
		"": false,
	}
	for u, want := range cases {
		if got := MatchPlaylist(u); got != want {
			t.Fatalf("MatchPlaylist(%q)=%v want %v", u, got, want)
		}
	}
}

func TestNeedsPlaylistExpand(t *testing.T) {
	vod := &model.Vod{
		VodFlags: []model.Flag{{
			Episodes: []model.Episode{
				{Name: "1", URL: "https://www.youtube.com/playlist?list=PLabc"},
			},
		}},
	}
	if !NeedsPlaylistExpand(vod) {
		t.Fatal("expected NeedsPlaylistExpand")
	}
	vod.VodFlags[0].Episodes[0].URL = "https://www.youtube.com/watch?v=abc"
	if NeedsPlaylistExpand(vod) {
		t.Fatal("single watch must not need playlist expand")
	}
}
