package spider

import (
	"testing"

	"github.com/bobo/KOTV/internal/util"
)

func TestJarIdentitySameURLDifferentMD5(t *testing.T) {
	base := "https://example.com/cfg/"
	jar := "https://example.com/Yoursmile.jar"
	a, _, okA := jarIdentity(jar+";md5;aaa", base)
	b, _, okB := jarIdentity(jar+";md5;bbb", base)
	c, _, okC := jarIdentity(jar+";md5;aaa", base)
	if !okA || !okB || !okC {
		t.Fatal("identity")
	}
	if a == b {
		t.Fatal("same url different md5 must be a new jar")
	}
	if a != c {
		t.Fatal("same url and md5")
	}
}

func TestJarIdentityRelativeUsesOwnConfig(t *testing.T) {
	xia := "https://tv.bobohome.store:20250/🧑潇洒哥/"
	ao := "https://tv.bobohome.store:20250/🐅嗷呜/"
	a, _, okA := jarIdentity("./spider.jar", xia)
	b, _, okB := jarIdentity("./spider.jar", ao)
	if !okA || !okB {
		t.Fatal("identity")
	}
	if a == b {
		t.Fatal("./spider.jar must resolve with its own config url")
	}
	wAo, _, okW := jarIdentity("./jars/Woshinidie.jar", ao)
	wXia, _, okX := jarIdentity("./jars/Woshinidie.jar", xia)
	if !okW || !okX || wAo == wXia {
		t.Fatal("relative site jar must keep the config it was loaded from")
	}
	filled := util.ResolveJarURL(xia, "./spider.jar")
	abs, _, okAbs := jarIdentity(filled, xia)
	if !okAbs || abs != a {
		t.Fatalf("relative and resolved: %s vs %s (%s)", a, abs, filled)
	}
}

func TestJarIDSetAowuSecondJarNotInXia(t *testing.T) {
	xia := "https://tv.bobohome.store:20250/🧑潇洒哥/"
	ao := "https://tv.bobohome.store:20250/🐅嗷呜/"
	wID, _, ok := jarIdentity("./jars/Woshinidie.jar", ao)
	if !ok {
		t.Fatal("identity")
	}
	aoSet := jarIDSet(ao, "./spider.jar", []string{"./spider.jar", "./jars/Woshinidie.jar"})
	xiaSet := jarIDSet(xia, "./spider.jar", []string{"./spider.jar"})
	if _, ok := aoSet[wID]; !ok {
		t.Fatal("aowu set missing second jar")
	}
	if _, ok := xiaSet[wID]; ok {
		t.Fatal("xia set contains aowu second jar")
	}
	rootAo, _, okAo := jarIdentity("./spider.jar", ao)
	rootXia, _, okXia := jarIdentity("./spider.jar", xia)
	if !okAo || !okXia || rootAo == rootXia {
		t.Fatal("roots must differ")
	}
	if _, ok := xiaSet[rootAo]; ok {
		t.Fatal("xia set contains aowu root")
	}
}

func TestJarIDSetKeepsDistinctMD5(t *testing.T) {
	base := "https://example.com/box/"
	jar := "https://example.com/a.jar"
	set := jarIDSet(base, "", []string{jar + ";md5;aaa", jar + ";md5;bbb"})
	if len(set) != 2 {
		t.Fatalf("got %d", len(set))
	}
}
