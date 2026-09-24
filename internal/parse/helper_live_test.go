package parse_test

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/bobo/KOTV/internal/model"
	"github.com/bobo/KOTV/internal/parse"
)

func TestResolveLiveURL_ParseOneSkipsVodType1(t *testing.T) {
	fakePlay := "http://cdn.example/very-long-fake-m3u8-address-over-forty-chars.m3u8"
	jx := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(`{"url":"` + fakePlay + `"}`))
	}))
	t.Cleanup(jx.Close)
	page := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte(`<html><body>no video</body></html>`))
	}))
	t.Cleanup(page.Close)

	parses := []model.Parse{{
		Name: "jx",
		Type: model.FlexInt{Valid: true, Value: 1},
		URL:  jx.URL + "?url=",
	}}
	out, _, err := parse.ResolveLiveURL(page.URL, true, parses, nil, "", "jx")
	if out == fakePlay || strings.Contains(out, "very-long-fake") {
		t.Fatalf("live parse=1 must not use vod type1 jx, got out=%q err=%v", out, err)
	}
}
