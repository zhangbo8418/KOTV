package service

import (
	"testing"

	"github.com/bobo/KOTV/internal/model"
)

func TestApplySourceFetch_MatchForcesParseZero(t *testing.T) {
	r := model.Result{
		Parse: model.FlexInt{Valid: true, Value: 1},
		URL:   model.URL{URLs: []string{"https://www.youtube.com/watch?v=dQw4w9WgXcQ"}},
	}
	applySourceFetch(&r)
	if !r.Parse.Is(0) {
		t.Fatalf("Match url must set parse=0, got %#v", r.Parse)
	}
}

func TestApplySourceFetch_VideoForcesParseOne(t *testing.T) {
	r := model.Result{
		Parse: model.FlexInt{Valid: true, Value: 0},
		URL:   model.URL{URLs: []string{"video://http://cdn.example/a.m3u8"}},
	}
	applySourceFetch(&r)
	if r.URL.URLs[0] != "http://cdn.example/a.m3u8" {
		t.Fatalf("video:// not stripped: %q", r.URL.URLs[0])
	}
	if !r.Parse.Is(1) {
		t.Fatalf("video:// must set parse=1, got %#v", r.Parse)
	}
}
