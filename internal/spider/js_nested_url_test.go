package spider

import (
	"net/http"
	"strings"
	"testing"
)

func TestPreserveNestedURLPath_KeepsColonInRequestURI(t *testing.T) {
	raw := "http://127.0.0.1:10079/c/3600/null/http://127.0.0.1:35456/all.m3u"
	req, err := http.NewRequest(http.MethodGet, raw, nil)
	if err != nil {
		t.Fatal(err)
	}
	before := req.URL.EscapedPath()
	if !strings.Contains(before, "%3A") {
		t.Fatalf("expected EscapedPath to encode colon, got %q", before)
	}
	preserveNestedURLPath(req)
	got := req.URL.RequestURI()
	want := "/c/3600/null/http://127.0.0.1:35456/all.m3u"
	if got != want {
		t.Fatalf("RequestURI=%q want %q", got, want)
	}
}

func TestPreserveNestedURLPath_NoopForPlainPath(t *testing.T) {
	req, err := http.NewRequest(http.MethodGet, "http://127.0.0.1:9978/api/v1/health", nil)
	if err != nil {
		t.Fatal(err)
	}
	preserveNestedURLPath(req)
	if req.URL.Opaque != "" {
		t.Fatalf("opaque should stay empty, got %q", req.URL.Opaque)
	}
	if req.URL.Path != "/api/v1/health" {
		t.Fatalf("path=%q", req.URL.Path)
	}
}
