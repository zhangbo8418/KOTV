package server

import (
	"net/http"
	"strconv"
	"testing"

	"github.com/bobo/KOTV/internal/auth"
	"github.com/bobo/KOTV/internal/settings"
)

func TestLoopbackBehindProxyIsRemote(t *testing.T) {
	t.Parallel()
	r, _ := http.NewRequest(http.MethodGet, "http://127.0.0.1:9978/api/v1/home", nil)
	r.RemoteAddr = "127.0.0.1:5000"
	if !isLoopbackRequest(r) {
		t.Fatal("direct loopback is local")
	}
	r.Header.Set("X-Forwarded-For", "203.0.113.9")
	if isLoopbackRequest(r) {
		t.Fatal("request forwarded by a reverse proxy must count as remote")
	}
}

func TestProtocolMismatch(t *testing.T) {
	t.Parallel()
	req := func(addr, path, proto string) *http.Request {
		r, _ := http.NewRequest(http.MethodGet, "http://h:9978"+path, nil)
		r.RemoteAddr = addr
		if proto != "" {
			r.Header.Set("X-Kotv-Protocol", proto)
		}
		return r
	}
	const lan = "192.168.1.8:5000"
	if protocolMismatch(req("127.0.0.1:5000", "/api/v1/home", "")) {
		t.Fatal("loopback is never checked")
	}
	if protocolMismatch(req(lan, "/api/v1/health", "")) {
		t.Fatal("health is never checked")
	}
	if !protocolMismatch(req(lan, "/api/v1/home", "")) || !protocolMismatch(req(lan, "/api/v1/home", "0")) {
		t.Fatal("missing or old protocol must be rejected")
	}
	if protocolMismatch(req(lan, "/api/v1/home", strconv.Itoa(ProtocolVersion))) {
		t.Fatal("same protocol must pass")
	}
}

func TestClientLabel(t *testing.T) {
	t.Parallel()
	r, _ := http.NewRequest(http.MethodGet, "http://h/api/v1/auth/login", nil)
	if got := clientLabel(r); got != "" {
		t.Fatalf("empty headers -> %q", got)
	}
	r.Header.Set("X-Kotv-Client-Platform", "android")
	r.Header.Set("X-Kotv-Client-Version", "0.3.0")
	if got := clientLabel(r); got != "android 0.3.0" {
		t.Fatalf("missing arch -> %q", got)
	}
	r.Header.Set("X-Kotv-Client-Arch", "arm64")
	if got := clientLabel(r); got != "android arm64 0.3.0" {
		t.Fatalf("full -> %q", got)
	}
}

func TestRemoteAccessAllowed(t *testing.T) {
	settings.Set(settings.RemoteAuth, "false")
	defer settings.Set(settings.RemoteAuth, "false")

	newReq := func(addr string, h http.Header) *http.Request {
		r, _ := http.NewRequest(http.MethodGet, "http://h:9978/api/v1/home", nil)
		r.RemoteAddr = addr
		for k, v := range h {
			r.Header[k] = v
		}
		return r
	}
	loop := newReq("127.0.0.1:12345", nil)
	if !remoteAccessAllowed(loop) {
		t.Fatal("loopback always allowed")
	}
	if !isLocalNative(loop) {
		t.Fatal("native loopback should be local native")
	}
	if !isAdmin(loop, nil) {
		t.Fatal("native loopback is admin without login")
	}
	lan := newReq("192.168.1.8:54321", nil)
	if remoteAccessAllowed(lan) {
		t.Fatal("LAN without remoteAuth must be denied")
	}
	webLan := newReq("192.168.1.8:54321", http.Header{"X-Kotv-Client-Platform": []string{"web"}})
	if !remoteAccessAllowed(webLan) {
		t.Fatal("Web same-origin must be allowed without remoteAuth")
	}
	if !loginRequired(webLan) {
		t.Fatal("Web must still require login")
	}
	// 静态页（无 platform）：本机免登、可管理
	staticLoop := newReq("127.0.0.1:12345", nil)
	if !isLocalNative(staticLoop) || !isAdmin(staticLoop, nil) || loginRequired(staticLoop) {
		t.Fatal("static loopback must be local-native admin without login")
	}
	// Flutter Web（platform=web）：即使 127.0.0.1 也要登录，不能免登管理
	webLoop := newReq("127.0.0.1:12345", http.Header{"X-Kotv-Client-Platform": []string{"web"}})
	if isLocalNative(webLoop) {
		t.Fatal("Flutter Web on loopback is not local native")
	}
	if !loginRequired(webLoop) {
		t.Fatal("Flutter Web on loopback must require login")
	}
	if isAdmin(webLoop, nil) {
		t.Fatal("Flutter Web on loopback must not be admin without account")
	}
	if !isAdmin(webLoop, &auth.User{Role: auth.RoleAdmin}) {
		t.Fatal("Flutter Web admin token should pass isAdmin")
	}

	settings.Set(settings.RemoteAuth, "true")
	if !remoteAccessAllowed(lan) {
		t.Fatal("LAN with remoteAuth must be allowed")
	}
	if !auth.RemoteAuthEnabled() {
		t.Fatal("remoteAuth should read true")
	}
}

func TestWebUiQueryPlatform(t *testing.T) {
	settings.Set(settings.RemoteAuth, "false")
	defer settings.Set(settings.RemoteAuth, "false")

	req, err := http.NewRequest(http.MethodGet, "http://192.168.1.8:9978/ui?role=ui&platform=web", nil)
	if err != nil {
		t.Fatal(err)
	}
	req.RemoteAddr = "192.168.1.8:54321"
	if !isWebClient(req) {
		t.Fatal("ui query platform should count as web")
	}
	if !remoteAccessAllowed(req) {
		t.Fatal("web ui socket should be allowed without remoteAuth")
	}
	if !loginRequired(req) {
		t.Fatal("web ui still requires login")
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
