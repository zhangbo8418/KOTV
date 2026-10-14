package server

import (
	"net/http"
	"testing"

	"github.com/bobo/KOTV/internal/auth"
	"github.com/bobo/KOTV/internal/settings"
)

func TestProbeOnlyPath(t *testing.T) {
	t.Parallel()
	if !probeOnlyPath("/api/v1/health") || !probeOnlyPath("/api/v1/auth/status") {
		t.Fatal("probe paths should be allowed")
	}
	if probeOnlyPath("/api/v1/auth/login") || probeOnlyPath("/api/v1/home") {
		t.Fatal("login/home must not be probe-only")
	}
}

func TestRemoteAccessAllowed(t *testing.T) {
	settings.Set(settings.RemoteAuth, "false")
	defer settings.Set(settings.RemoteAuth, "false")

	loop := &http.Request{RemoteAddr: "127.0.0.1:12345"}
	if !remoteAccessAllowed(loop) {
		t.Fatal("loopback always allowed")
	}
	lan := &http.Request{RemoteAddr: "192.168.1.8:54321"}
	if remoteAccessAllowed(lan) {
		t.Fatal("LAN without remoteAuth must be denied")
	}
	webLan := &http.Request{
		RemoteAddr: "192.168.1.8:54321",
		Header:     http.Header{"X-Kotv-Client-Platform": []string{"web"}},
	}
	if !remoteAccessAllowed(webLan) {
		t.Fatal("Web same-origin must be allowed without remoteAuth")
	}
	if !authRequiredFor(webLan) {
		t.Fatal("Web must still require login")
	}

	settings.Set(settings.RemoteAuth, "true")
	if !remoteAccessAllowed(lan) {
		t.Fatal("LAN with remoteAuth must be allowed")
	}
	if !auth.RemoteAuthEnabled() {
		t.Fatal("remoteAuth should read true")
	}
}

func TestRequestPublicBasePrefersClientEngine(t *testing.T) {
	req, err := http.NewRequest(http.MethodGet, "http://192.168.0.113:9978/api/v1/play", nil)
	if err != nil {
		t.Fatal(err)
	}
	req.Host = "192.168.0.113:9978"
	req.Header.Set("X-Forwarded-Host", "10.0.0.8:9978")
	req.Header.Set("X-Kotv-Engine-Base", "https://tv.example.com:8443/ignored")
	if got := requestPublicBase(req); got != "https://tv.example.com:8443" {
		t.Fatalf("client base=%q", got)
	}
	req.Header.Set("X-Kotv-Engine-Base", "http://127.0.0.1:9978")
	if got := requestPublicBase(req); got != "http://10.0.0.8:9978" {
		t.Fatalf("loopback client base should fall through, got %q", got)
	}
}
