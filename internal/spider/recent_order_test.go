package spider

import (
	"testing"
)

func TestSetRecent_JSBeforePyWhenBoth(t *testing.T) {
	// api 同时含 .js 与 .py 时 recent 记 js。
	Clear()
	t.Cleanup(Clear)
	api := "http://example.com/spider.js.py"
	if !isJS(api) || !isPy(api) {
		t.Fatalf("fixture must match both .js and .py: %q", api)
	}
	SetRecent("k1", api, "{}", "")
	if recentJsKey == "" {
		t.Fatal("expected recent js key when api contains .js")
	}
	if recentPyKey != "" {
		t.Fatalf("py recent must stay empty when js wins, got %q", recentPyKey)
	}
}

func TestGet_PyBeforeJSWhenBoth(t *testing.T) {
	// api 同时含 .js 与 .py 时 Get 走 py。
	Clear()
	t.Cleanup(Clear)
	api := "http://example.com/spider.js.py"
	sp := Get("k2", api, "{}", "")
	if _, ok := sp.(*pyPool); !ok {
		t.Fatalf("want *pyPool when api has .py, got %T", sp)
	}
}

func TestSameScriptReusedUntilLeft(t *testing.T) {
	Clear()
	t.Cleanup(Clear)
	first := newPySpider("site-a", "http://example.com/a.py", "e1", "")
	again := newPySpider("site-b", "http://example.com/a.py", "e2", "")
	if first != again {
		t.Fatal("同一份 py 应复用已有池")
	}
	if again.(*pyPool).ext != "e2" {
		t.Fatal("同一池应改用新的 ext")
	}
	other := newPySpider("site-c", "http://example.com/b.py", "", "")
	if other == first {
		t.Fatal("另一份 py 应另开一池")
	}
	ReleaseOtherScripts("http://example.com/b.py")
	jsPyMu.Lock()
	defer jsPyMu.Unlock()
	if _, ok := jsPy[jsPyKey("py", "http://example.com/a.py")]; ok {
		t.Fatal("离开的 py 应关掉")
	}
	if _, ok := jsPy[jsPyKey("py", "http://example.com/b.py")]; !ok {
		t.Fatal("当前 py 应留着")
	}
}

func TestIsCSP(t *testing.T) {
	if !isCSP("csp_XPath") {
		t.Fatal("csp_ prefix")
	}
	if isCSP("http://x/csp_foo.js") {
		t.Fatal("http api is not csp")
	}
}
