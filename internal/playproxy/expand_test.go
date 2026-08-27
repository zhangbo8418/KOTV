package playproxy

import (
	"encoding/base64"
	"encoding/json"
	"net/url"
	"testing"
)

func TestExpandSpiderMediaProxyQuark(t *testing.T) {
	t.Parallel()
	cdn := "https://cdn-quark.example/video/01.mkv"
	hdr := map[string]string{"Cookie": "c=1", "User-Agent": "ua"}
	hb, _ := json.Marshal(hdr)
	raw := "proxy://do=quark&type=video&url=" +
		url.QueryEscape(base64.StdEncoding.EncodeToString([]byte(cdn))) +
		"&header=" + url.QueryEscape(base64.StdEncoding.EncodeToString(hb))

	gotURL, gotHdr, ok := ExpandSpiderMediaProxy(raw, map[string]string{"Referer": "https://keep.example/"})
	if !ok {
		t.Fatal("expected expand")
	}
	if gotURL != cdn {
		t.Fatalf("url=%q want %q", gotURL, cdn)
	}
	if gotHdr["Cookie"] != "c=1" || gotHdr["User-Agent"] != "ua" {
		t.Fatalf("headers=%v", gotHdr)
	}
	if gotHdr["Referer"] != "https://keep.example/" {
		t.Fatalf("should keep existing Referer: %v", gotHdr)
	}
}

func TestExpandSpiderMediaProxySkipsM3U8(t *testing.T) {
	t.Parallel()
	cdn := "https://cdn.example/a.m3u8"
	raw := "http://127.0.0.1:9978/proxy?do=quark&type=video&url=" +
		base64.StdEncoding.EncodeToString([]byte(cdn))
	if _, _, ok := ExpandSpiderMediaProxy(raw, nil); ok {
		t.Fatal("m3u8 must not expand")
	}
}

func TestExpandSpiderMediaProxyIgnoresPlain(t *testing.T) {
	t.Parallel()
	if _, _, ok := ExpandSpiderMediaProxy("https://cdn.example/a.mkv", nil); ok {
		t.Fatal("plain url must not expand")
	}
}
