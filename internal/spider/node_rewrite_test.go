package spider

import (
	"strings"
	"testing"

	"github.com/bobo/KOTV/internal/hostclient"
	"github.com/bobo/KOTV/internal/localproxy"
	"github.com/bobo/KOTV/internal/playproxy"
)

func TestRewritePlayJSON(t *testing.T) {
	localproxy.SetPort(9978)
	p := &nodePkg{id: "abc123def456", port: 12345}
	in := `{
		"parse":0,
		"url":"js2p://_WEB_/spider/ffm3u8/3/proxy/hls/x/.m3u8",
		"url2":"http://127.0.0.1:12345/spider/a/3/proxy/ts/y/.ts",
		"url3":"http://localhost:12345/other"
	}`
	out := p.RewritePlayJSON(in)
	engine := "http://127.0.0.1:9978/node/abc123def456"
	if strings.Contains(out, "js2p://") {
		t.Fatalf("js2p not rewritten: %s", out)
	}
	if strings.Contains(out, "127.0.0.1:12345") || strings.Contains(out, "localhost:12345") {
		t.Fatalf("local port not rewritten: %s", out)
	}
	if !strings.Contains(out, engine+"/spider/ffm3u8/3/proxy/hls/x/.m3u8") {
		t.Fatalf("missing rewritten js2p path: %s", out)
	}
	if !strings.Contains(out, engine+"/spider/a/3/proxy/ts/y/.ts") {
		t.Fatalf("missing rewritten local url: %s", out)
	}
}

func TestRewriteNodeURL(t *testing.T) {
	localproxy.SetPort(9978)
	p := &nodePkg{id: "pkg1", port: 9999}
	got := p.RewriteNodeURL("http://127.0.0.1:9999/danmu/abc")
	want := "http://127.0.0.1:9978/node/pkg1/danmu/abc"
	if got != want {
		t.Fatalf("got %q want %q", got, want)
	}
	got = p.RewriteNodeURL("http://127.0.0.1:9999/website")
	want = "http://127.0.0.1:9978/node/pkg1/website"
	if got != want {
		t.Fatalf("website play/danmu path got %q want %q", got, want)
	}
}

func TestRewriteNodeURLRemotePublicize(t *testing.T) {
	localproxy.SetPort(9978)
	playproxy.SetEngineRoutes([]string{"/node/"})
	t.Cleanup(func() { playproxy.SetEngineRoutes(nil) })
	defer hostclient.Bind(hostclient.Request{
		ClientID:   "node-pub",
		PublicBase: "https://tv.example.com/k/KEY",
	})()
	p := &nodePkg{id: "pkg1", port: 9999}
	got := p.RewriteNodeURL("http://127.0.0.1:9999/danmu/abc")
	want := "https://tv.example.com/k/KEY/node/pkg1/danmu/abc"
	if got != want {
		t.Fatalf("got %q want %q", got, want)
	}
	got = p.RewriteNodeURL("http://127.0.0.1:9999/website")
	wantWeb := "https://tv.example.com/k/KEY/node/pkg1/website"
	if got != wantWeb {
		t.Fatalf("website remote got %q want %q", got, wantWeb)
	}
	out := p.RewritePlayJSON(`{"url":"js2p://_WEB_/x.m3u8"}`)
	if !strings.Contains(out, want[:strings.Index(want, "/danmu")]) {
		t.Fatalf("play json not publicized: %s", out)
	}
}

func TestRewriteOpenWebURLLocalKeep(t *testing.T) {
	localproxy.SetPort(9978)
	h := DefaultNodeHost()
	h.mu.Lock()
	h.rootAliases = map[string]struct{}{}
	h.mu.Unlock()
	p := &nodePkg{id: "pkg1", port: 9999, host: h}
	raw := "http://127.0.0.1:9999/website"
	got := p.RewriteOpenWebURL(raw)
	if got != raw {
		t.Fatalf("local OPENWEB should keep node URL, got %q", got)
	}
	if !h.MatchNodeRootAlias("/website") {
		t.Fatal("OPENWEB should register root alias")
	}
}

func TestRewriteOpenWebURLRemoteNodeProxy(t *testing.T) {
	localproxy.SetPort(9978)
	playproxy.SetEngineRoutes([]string{"/node/"})
	t.Cleanup(func() { playproxy.SetEngineRoutes(nil) })
	defer hostclient.Bind(hostclient.Request{
		ClientID:   "ow",
		UserID:     "u1",
		Dedicated:  true,
		PublicBase: "https://tv.example.com/k/KEY",
		AuthToken:  "tok123",
	})()
	h := DefaultNodeHost() // Bind 后为 u1 独立桶
	h.mu.Lock()
	h.rootAliases = map[string]struct{}{}
	h.mu.Unlock()
	p := &nodePkg{id: "pkg1", port: 9999, ownerUID: "u1", host: h}
	got := p.RewriteOpenWebURL("http://127.0.0.1:9999/website")
	// 浏览器页不加 /k/<钥匙>，便于 ?token= 走用户会话并种根别名 Cookie。
	want := "https://tv.example.com/node/pkg1/website?token=tok123"
	if got != want {
		t.Fatalf("got %q want %q", got, want)
	}
	if !h.MatchNodeRootAlias("/website/api") {
		t.Fatal("expected website root alias")
	}
}

func TestStripPublicMediaKey(t *testing.T) {
	if got := stripPublicMediaKey("https://tv.example.com/k/KEY"); got != "https://tv.example.com" {
		t.Fatalf("got %q", got)
	}
	if got := stripPublicMediaKey("http://192.168.1.8:9978/k/abc123"); got != "http://192.168.1.8:9978" {
		t.Fatalf("got %q", got)
	}
}

func TestHandleNodeMsgToast(t *testing.T) {
	var got []string
	SetPostMsgEmitter(func(msg, clientID string) {
		got = append(got, msg)
	})
	t.Cleanup(func() { SetPostMsgEmitter(nil) })

	resp := HandleNodeMsg([]byte(`{"action":"toast","opt":{"message":"你好"}}`))
	if m, ok := resp.(map[string]any); !ok || m["ok"] != true {
		t.Fatalf("resp=%v", resp)
	}
	if len(got) != 1 || got[0] != "你好" {
		t.Fatalf("got %v", got)
	}
}

func TestHandleNodeMsgGetPlayInfo(t *testing.T) {
	SetCurrentPlayInfo("牧神记", "第01集", "线路1")
	t.Cleanup(func() { SetCurrentPlayInfo("", "", "") })
	resp := HandleNodeMsg([]byte(`{"action":"getPlayInfo"}`))
	m, ok := resp.(map[string]any)
	if !ok {
		t.Fatalf("resp=%T", resp)
	}
	if m["title"] != "牧神记" || m["episodeName"] != "第01集" || m["flag"] != "线路1" {
		t.Fatalf("resp=%v", m)
	}
}

func TestHandleNodeMsgUnknown(t *testing.T) {
	if HandleNodeMsg([]byte(`{"action":"nope"}`)) != nil {
		t.Fatal("want nil")
	}
}

func TestHandleNodeMsgOpenWebUsesCaller(t *testing.T) {
	localproxy.SetPort(9978)
	playproxy.SetEngineRoutes([]string{"/node/"})
	t.Cleanup(func() { playproxy.SetEngineRoutes(nil) })

	h := DefaultNodeHost()
	p := &nodePkg{id: "pkg1", port: 9999, pkgURL: "http://example/index.js", host: h}
	h.mu.Lock()
	h.pkgs["pkg1"] = p
	h.rootAliases = map[string]struct{}{}
	h.mu.Unlock()
	t.Cleanup(func() {
		h.mu.Lock()
		delete(h.pkgs, "pkg1")
		h.mu.Unlock()
	})

	p.mu.Lock()
	p.caller = callerSnap{
		UserID:     "user-a",
		Scope:      "u:user-a",
		PublicBase: "https://tv.example.com/k/KEY",
		AuthToken:  "tok-a",
		Dedicated:  true,
	}
	p.mu.Unlock()

	var gotMsg, gotScope string
	SetPostMsgEmitter(func(msg, clientID string) {
		gotMsg, gotScope = msg, clientID
	})
	t.Cleanup(func() { SetPostMsgEmitter(nil) })

	resp := HandleNodeMsg([]byte(`{"action":"openInternalWebview","url":"http://127.0.0.1:9999/website"}`))
	if m, ok := resp.(map[string]any); !ok || m["ok"] != true {
		t.Fatalf("resp=%v", resp)
	}
	want := "OPENWEB:https://tv.example.com/node/pkg1/website?token=tok-a"
	if gotMsg != want {
		t.Fatalf("msg=%q want %q", gotMsg, want)
	}
	if gotScope != "u:user-a" {
		t.Fatalf("scope=%q", gotScope)
	}
	if !TakeDetailOpenWeb("u:user-a") {
		t.Fatal("openInternalWebview should note detail openWeb for caller scope")
	}
	if TakeDetailOpenWeb("u:user-a") {
		t.Fatal("TakeDetailOpenWeb should clear")
	}
}
