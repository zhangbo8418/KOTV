package spider

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"testing"

	"github.com/bobo/KOTV/internal/localproxy"
)

func TestRewriteNodeActionWeb_RegistersAlias(t *testing.T) {
	localproxy.SetPort(9978)
	h := DefaultNodeHost()
	h.mu.Lock()
	h.rootAliases = map[string]struct{}{}
	h.mu.Unlock()
	p := &nodePkg{id: "actpkg", port: 9999, host: h}
	s := &nodeSpider{pkgID: "actpkg"}
	h.mu.Lock()
	h.pkgs["actpkg"] = p
	h.mu.Unlock()
	t.Cleanup(func() {
		h.mu.Lock()
		delete(h.pkgs, "actpkg")
		h.mu.Unlock()
	})

	raw := `{"web":{"url":"http://127.0.0.1:9999/website","mode":"view"},"msg":"ok"}`
	out := rewriteNodeActionWeb(raw, s)
	var m map[string]any
	if err := json.Unmarshal([]byte(out), &m); err != nil {
		t.Fatal(err)
	}
	web, _ := m["web"].(map[string]any)
	u, _ := web["url"].(string)
	if u != "http://127.0.0.1:9999/website" {
		t.Fatalf("local openweb url got %q", u)
	}
	if !h.MatchNodeRootAlias("/website") {
		t.Fatal("expected /website root alias")
	}
}

func TestNodeSpiderAction_PostsAction(t *testing.T) {
	var gotPath string
	var gotBody string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotPath = r.URL.Path
		b, _ := io.ReadAll(r.Body)
		gotBody = string(b)
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"msg":"hi","web":{"url":"http://127.0.0.1:9/website"}}`))
	}))
	t.Cleanup(srv.Close)

	u := srv.URL // http://127.0.0.1:PORT
	portStr := u[strings.LastIndex(u, ":")+1:]
	port, err := strconv.Atoi(portStr)
	if err != nil {
		t.Fatal(err)
	}

	h := DefaultNodeHost()
	pkg := &nodePkg{id: "actpost", port: port, host: h}
	h.mu.Lock()
	h.pkgs["actpost"] = pkg
	h.mu.Unlock()
	t.Cleanup(func() {
		h.mu.Lock()
		delete(h.pkgs, "actpost")
		h.mu.Unlock()
	})

	s := &nodeSpider{
		pkgID:  "actpost",
		prefix: "/spider/k/3",
		inited: true,
	}
	raw, err := s.Action("open-config")
	if err != nil {
		t.Fatal(err)
	}
	if gotPath != "/spider/k/3/action" {
		t.Fatalf("path=%q", gotPath)
	}
	if !strings.Contains(gotBody, `"action":"open-config"`) && !strings.Contains(gotBody, "open-config") {
		t.Fatalf("body=%q", gotBody)
	}
	if !strings.Contains(raw, `"web"`) {
		t.Fatalf("raw missing web: %s", raw)
	}
}
