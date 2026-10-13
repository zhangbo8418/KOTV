package live

import (
	"testing"

	"github.com/bobo/KOTV/internal/model"
)

func TestNeedsEnginePlay(t *testing.T) {
	direct := &model.LiveChannel{Parse: 0}
	needParse := &model.LiveChannel{Parse: 1}
	cases := []struct {
		ch   *model.LiveChannel
		url  string
		want bool
	}{
		{direct, "https://example.com/a.m3u8", false},
		{needParse, "https://example.com/a.m3u8", true},
		{direct, "json:http://x", true},
		{direct, "parse:http://x", true},
		{direct, "video:http://x", true},
		{direct, "tvbus://x", true},
		{direct, "https://www.youtube.com/watch?v=1", true},
		{direct, "", true},
	}
	for _, c := range cases {
		if got := NeedsEnginePlay(c.ch, c.url); got != c.want {
			t.Fatalf("NeedsEnginePlay(parse=%d, %q)=%v want %v", c.ch.Parse, c.url, got, c.want)
		}
	}
}
