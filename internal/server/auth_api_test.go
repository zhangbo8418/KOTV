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

	settings.Set(settings.RemoteAuth, "true")
	if !remoteAccessAllowed(lan) {
		t.Fatal("LAN with remoteAuth must be allowed")
	}
	if !auth.RemoteAuthEnabled() {
		t.Fatal("remoteAuth should read true")
	}
}
