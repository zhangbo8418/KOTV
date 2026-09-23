package spider

import (
	"strings"
	"testing"
)

func TestBuildJSPostBody(t *testing.T) {
	t.Run("json", func(t *testing.T) {
		opt := jsHTTPRequest{
			Data:     `{"a":1}`,
			PostType: "json",
			Headers:  map[string]string{},
		}
		body := buildJSPostBody(&opt)
		if body != `{"a":1}` {
			t.Fatalf("json body=%q", body)
		}
		if ct := headerValue(opt.Headers, "Content-Type"); !strings.Contains(ct, "application/json") {
			t.Fatalf("json Content-Type=%q", ct)
		}
	})
	t.Run("unknown ignores data", func(t *testing.T) {
		opt := jsHTTPRequest{
			Data:     `{"a":1}`,
			PostType: "raw",
			Headers:  map[string]string{},
		}
		body := buildJSPostBody(&opt)
		if body != "" {
			t.Fatalf("unknown postType must not send data, got %q", body)
		}
	})
	t.Run("unknown falls back to body+CT", func(t *testing.T) {
		opt := jsHTTPRequest{
			Data:     `{"a":1}`,
			Body:     "plain",
			PostType: "xml",
			Headers:  map[string]string{"Content-Type": "text/plain"},
		}
		body := buildJSPostBody(&opt)
		if body != "plain" {
			t.Fatalf("want body fallback got %q", body)
		}
	})
	t.Run("form", func(t *testing.T) {
		opt := jsHTTPRequest{
			Data:     `{"k":"v"}`,
			PostType: "form",
			Headers:  map[string]string{},
		}
		body := buildJSPostBody(&opt)
		if body != "k=v" {
			t.Fatalf("form body=%q", body)
		}
	})
}
