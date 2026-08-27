package config

import "testing"

func TestResolveSiteField_OpaqueExtToken(t *testing.T) {
	base := "https://tv.bobohome.store:20250/aowu/"
	for _, tok := range []string{"Hgdh", "Guazi", "woWogg", "NewGrV2", "Douban"} {
		got := resolveSiteField(base, tok)
		if got != tok {
			t.Fatalf("opaque ext %q must stay unchanged, got %q", tok, got)
		}
	}
}

func TestResolveSiteField_RelativePath(t *testing.T) {
	base := "https://example.com/cfg/"
	got := resolveSiteField(base, "./spider.jar")
	if got != "https://example.com/cfg/spider.jar" {
		t.Fatalf("relative jar: got %q", got)
	}
	got = resolveSiteField(base, "csp_Foo")
	if got != "csp_Foo" {
		t.Fatalf("csp api: got %q", got)
	}
}
