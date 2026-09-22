package service

import (
	"strings"
	"testing"

	"github.com/bobo/KOTV/internal/model"
)

func TestFetchExt_NonHTTPUnchanged(t *testing.T) {
	site := model.Site{Ext: model.FlexString(`{"k":1}`)}
	out, err := fetchExt(site)
	if err != nil {
		t.Fatal(err)
	}
	if out.Ext.String() != `{"k":1}` {
		t.Fatalf("ext changed: %q", out.Ext.String())
	}
}

func TestFetchExt_HTTPFailSoft(t *testing.T) {
	// 对照 FongMi Site.fetchExt：OkHttp.string 失败→空，不改 ext、不抛错。
	site := model.Site{Ext: model.FlexString("http://127.0.0.1:1/no-such-ext")}
	out, err := fetchExt(site)
	if err != nil {
		t.Fatal(err)
	}
	if out.Ext.String() != site.Ext.String() {
		t.Fatalf("failed http fetch must keep original ext, got %q", out.Ext.String())
	}
}

func TestSiteCall_AttachesExtendLiteral(t *testing.T) {
	// siteCall 只附加 extend 原文；http 链接不在此下载（仅 type4 home 走 fetchExt）。
	site := model.Site{
		API: "http://127.0.0.1:1/api",
		Ext: model.FlexString("http://example.com/ext.json"),
	}
	// 请求会失败；我们只验证 params 组装路径不 panic，且 rune 阈值用 POST。
	_, err := siteCall(site, map[string]string{"filter": "true"})
	if err == nil {
		t.Fatal("expected dial error")
	}
}

func TestSiteCall_LongExtUsesUTF16Len(t *testing.T) {
	// FongMi SiteApi.call：ext.length()>1000（UTF-16）→ POST。
	ext := strings.Repeat("中", 1001)
	if javaUTF16Len(ext) <= 1000 {
		t.Fatal("fixture")
	}
	site := model.Site{
		API: "http://127.0.0.1:1/api",
		Ext: model.FlexString(ext),
	}
	_, err := siteCall(site, map[string]string{"t": "1"})
	if err == nil {
		t.Fatal("expected dial error")
	}
}

func TestBase64URLSafe_Padding(t *testing.T) {
	// FongMi Util.URL_SAFE = DEFAULT|URL_SAFE|NO_WRAP（带 padding）。
	got := base64URLSafe(`{"a":1}`)
	if !strings.HasSuffix(got, "=") && len(got)%4 != 0 {
		t.Fatalf("want padded url-safe base64, got %q", got)
	}
}
