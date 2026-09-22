package spider

import (
	"testing"
)

func TestSetRecent_JSBeforePyWhenBoth(t *testing.T) {
	// 对照 FongMi BaseLoader.setRecent：isJs 先于 isPy。
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
	// 对照 FongMi BaseLoader.getSpider：isPy 先于 isJs。
	Clear()
	t.Cleanup(Clear)
	api := "http://example.com/spider.js.py"
	sp := Get("k2", api, "{}", "")
	if _, ok := sp.(*pyPool); !ok {
		t.Fatalf("want *pyPool when api has .py, got %T", sp)
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
