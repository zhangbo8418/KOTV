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

func TestPoolAcquireAfterDestroy(t *testing.T) {
	py := newPyPool("k", "http://example.com/a.py", "", "")
	if _, _, err := py.acquire(); err != nil {
		t.Fatal(err)
	}
	py.Destroy()
	if _, _, err := py.acquire(); err == nil {
		t.Fatal("销毁后的 Python 池不应再拉起进程")
	}
	js := newJsPool("k", "http://example.com/a.js", "", "")
	if _, _, err := js.acquire(); err != nil {
		t.Fatal(err)
	}
	js.Destroy()
	if _, _, err := js.acquire(); err == nil {
		t.Fatal("销毁后的 JS 池不应再开 Runtime")
	}
}

func TestPyStartLockedAfterDestroy(t *testing.T) {
	s := &pySpider{key: "k", api: "http://example.com/a.py"}
	s.Destroy()
	s.mu.Lock()
	err := s.startLocked("python", "runner", "script")
	s.mu.Unlock()
	if err == nil {
		t.Fatal("已销毁的 Python 不应再启动进程")
	}
}

func TestReleaseConfigScriptsClearsCurrentUserOnly(t *testing.T) {
	Clear()
	t.Cleanup(Clear)
	jsPyMu.Lock()
	jsPy["\x01py:http://example.com/a.py"] = newPyPool("a", "http://example.com/a.py", "", "")
	jsPy["\x01js:http://example.com/a.js"] = newJsPool("a", "http://example.com/a.js", "", "")
	jsPy["u2\x01py:http://example.com/b.py"] = newPyPool("b", "http://example.com/b.py", "", "")
	recentPyKey = "\x01py:http://example.com/missing.py"
	recentJsKey = "u2\x01js:http://example.com/b.js"
	jsPyMu.Unlock()

	releaseConfigScripts()

	jsPyMu.Lock()
	defer jsPyMu.Unlock()
	if _, ok := jsPy["\x01py:http://example.com/a.py"]; ok {
		t.Fatal("切仓应清掉当前用户的全部 py")
	}
	if _, ok := jsPy["\x01js:http://example.com/a.js"]; ok {
		t.Fatal("切仓应清掉当前用户的全部 js")
	}
	if _, ok := jsPy["u2\x01py:http://example.com/b.py"]; !ok {
		t.Fatal("切仓不应清掉其他用户")
	}
	if recentPyKey != "" {
		t.Fatal("当前用户的 recent 应清掉")
	}
	if recentJsKey != "u2\x01js:http://example.com/b.js" {
		t.Fatalf("其他用户 recent 应留着, got %q", recentJsKey)
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
