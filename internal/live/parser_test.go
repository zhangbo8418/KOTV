package live

import (
	"testing"

	"github.com/bobo/KOTV/internal/model"
)

func TestParseTXT_GroupPassSplitsAtFirstUnderscore(t *testing.T) {
	live := &model.Live{}
	Parse(live, "央视_a_b,#genre#\nCCTV1,http://x/1.m3u8\n")
	if len(live.Groups) != 1 {
		t.Fatalf("groups=%d", len(live.Groups))
	}
	g := live.Groups[0]
	if g.Name != "央视" || g.Pass != "a_b" {
		t.Fatalf("name=%q pass=%q", g.Name, g.Pass)
	}
}

func TestParseTXT_LivePassDisablesGroupPassword(t *testing.T) {
	live := &model.Live{Pass: true}
	Parse(live, "央视_123,#genre#\nCCTV1,http://x/1.m3u8\n")
	g := live.Groups[0]
	if g.Name != "央视" || g.Pass != "" {
		t.Fatalf("name=%q pass=%q", g.Name, g.Pass)
	}
}

func TestParse_AutoNumberIsZeroPadded(t *testing.T) {
	live := &model.Live{}
	Parse(live, "组,#genre#\nA,http://x/a\nB,http://x/b\n")
	chs := live.Groups[0].Channels
	if chs[0].Number != "001" || chs[1].Number != "002" {
		t.Fatalf("numbers=%q %q", chs[0].Number, chs[1].Number)
	}
}

func TestParseM3U_ClickAndCookie(t *testing.T) {
	live := &model.Live{}
	text := "#EXTM3U tvg-url=http://epg/x.xml\n" +
		"#EXTINF:-1 group-title=\"G\",C1\n" +
		"click=document.querySelector('a').click()\n" +
		"#EXTVLCOPT:http-cookie=\"sid=1\"\n" +
		"http://x/c1.m3u8\n"
	Parse(live, text)
	if live.EPG != "http://epg/x.xml" {
		t.Fatalf("unquoted tvg-url not read: %q", live.EPG)
	}
	ch := live.Groups[0].Channels[0]
	if ch.Click != "document.querySelector('a').click()" {
		t.Fatalf("click=%q", ch.Click)
	}
	if ch.Header["Cookie"] != "sid=1" {
		t.Fatalf("cookie header=%#v", ch.Header)
	}
}

func TestParseM3U_HeaderEpgOrderTvgUrlFirst(t *testing.T) {
	live := &model.Live{}
	Parse(live, "#EXTM3U url-tvg=\"http://b\" tvg-url=\"http://a\"\n#EXTINF:-1,C\nhttp://x\n")
	if live.EPG != "http://a" {
		t.Fatalf("epg=%q", live.EPG)
	}
}

func TestParseJSON_FullChannelFields(t *testing.T) {
	live := &model.Live{}
	text := `[{"name":"G","pass":"p","channel":[{"name":"C","logo":"l.png","number":"7","epg":"http://e",
	  "ua":"UA","click":"js","format":"mpd","origin":"http://o","referer":"http://r","tvgId":"id","tvgName":"tn",
	  "parse":1,"header":{"X":"1"},"catchup":{"source":"?s"},"drm":{"key":"http://k","type":"clearkey"},"urls":["http://u"]}]}]`
	Parse(live, text)
	if len(live.Groups) != 1 || live.Groups[0].Pass != "p" {
		t.Fatalf("group=%+v", live.Groups)
	}
	c := live.Groups[0].Channels[0]
	if c.Number != "7" || c.EPG != "http://e" || c.UA != "UA" || c.Click != "js" ||
		c.Format != "application/dash+xml" || c.Origin != "http://o" || c.Referer != "http://r" ||
		c.TvgID != "id" || c.TvgName != "tn" || c.Parse != 1 || c.Header["X"] != "1" ||
		c.Catchup == nil || c.Catchup.Source != "?s" || c.Drm == nil || c.Drm.Key != "http://k" ||
		len(c.URLs) != 1 {
		t.Fatalf("channel=%+v", c)
	}
}

func TestParseTXT_ParseZeroSticky(t *testing.T) {
	live := &model.Live{}
	Parse(live, "G,#genre#\nparse=1\nA,http://a\nparse=0\nB,http://b\n")
	chs := live.Groups[0].Channels
	if chs[0].Parse != 1 {
		t.Fatalf("A.Parse=%d want 1", chs[0].Parse)
	}
	if chs[1].Parse != 0 {
		t.Fatalf("B.Parse=%d want 0", chs[1].Parse)
	}
}

func TestParseTXT_UAStripQuotes(t *testing.T) {
	live := &model.Live{}
	Parse(live, "G,#genre#\nua=\"VLC/3.0\"\nreferer=\"http://r/\"\nC,http://c\n")
	ch := live.Groups[0].Channels[0]
	if ch.UA != "VLC/3.0" {
		t.Fatalf("UA=%q", ch.UA)
	}
	if ch.Referer != "http://r/" {
		t.Fatalf("Referer=%q", ch.Referer)
	}
}

func TestParseTXT_PipeHeadersOnURL(t *testing.T) {
	live := &model.Live{}
	Parse(live, "G,#genre#\nC,http://cdn/a.m3u8|User-Agent=\"VLC\"|Referer=\"http://r/\"\n")
	ch := live.Groups[0].Channels[0]
	if ch.Header["User-Agent"] != "VLC" {
		t.Fatalf("UA header=%q hdr=%v", ch.Header["User-Agent"], ch.Header)
	}
	if ch.Header["Referer"] != "http://r/" {
		t.Fatalf("Referer header=%q", ch.Header["Referer"])
	}
}

func TestParseTXT_PipeHeadersPreferPipeOverAmp(t *testing.T) {
	live := &model.Live{}
	Parse(live, "G,#genre#\nC,http://cdn/a.m3u8|User-Agent=VLC|Referer=http://x?a=1&b=2\n")
	ch := live.Groups[0].Channels[0]
	if ch.Header["User-Agent"] != "VLC" {
		t.Fatalf("UA header=%q hdr=%v", ch.Header["User-Agent"], ch.Header)
	}
	// 值内 & 仍再切（FongMi headers 同）：Referer 只保留到第一个 &。
	if ch.Header["Referer"] != "http://x?a=1" {
		t.Fatalf("Referer header=%q hdr=%v", ch.Header["Referer"], ch.Header)
	}
	if ch.Header["b"] != "2" {
		t.Fatalf("b header=%q hdr=%v", ch.Header["b"], ch.Header)
	}
}

func TestParseJSON_ParseZero(t *testing.T) {
	live := &model.Live{}
	text := `[{"name":"G","channel":[{"name":"C","parse":0,"urls":["http://u"]}]}]`
	Parse(live, text)
	if live.Groups[0].Channels[0].Parse != 0 {
		t.Fatalf("Parse=%d", live.Groups[0].Channels[0].Parse)
	}
}
