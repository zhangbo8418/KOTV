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
		{direct, "magnet:?xt=urn:btih:abc", true},
		{direct, "ed2k://|file|a.mp4|1|hash|/", true},
		{direct, "", true},
	}
	for _, c := range cases {
		if got := NeedsEnginePlay(c.ch, c.url); got != c.want {
			t.Fatalf("NeedsEnginePlay(parse=%d, %q)=%v want %v", c.ch.Parse, c.url, got, c.want)
		}
	}
}

func TestVodNeedsEnginePlay(t *testing.T) {
	xml := model.Site{Type: model.FlexInt{Valid: true, Value: 1}}
	spider := model.Site{Type: model.FlexInt{Valid: true, Value: 3}}
	withPlayURL := model.Site{Type: model.FlexInt{Valid: true, Value: 1}, PlayURL: "http://parse/"}
	m3u8 := "https://cdn.example.com/a.m3u8"
	cases := []struct {
		site model.Site
		url  string
		want bool
	}{
		{xml, m3u8, false},
		{spider, m3u8, true},
		{withPlayURL, m3u8, true},
		{xml, "json:http://x", true},
		{xml, "magnet:?xt=urn:btih:abc", true},
		{xml, "https://cdn.example.com/page.html", true},
	}
	for _, c := range cases {
		if got := VodNeedsEnginePlay(c.site, c.url, nil); got != c.want {
			t.Fatalf("VodNeedsEnginePlay(type=%d playURL=%q url=%q)=%v want %v",
				c.site.TypeID(), c.site.PlayURL, c.url, got, c.want)
		}
	}
}
