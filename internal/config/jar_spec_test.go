package config

import (
	"testing"

	"github.com/bobo/KOTV/internal/model"
)

func TestJarSpecsDedup(t *testing.T) {
	root := "https://example.com/Yoursmile.jar;md5;abc"
	png := "https://file.example/a.png"
	api := model.Api{
		Spider: root,
		Sites: []model.Site{
			{Key: "天天", Jar: root},
			{Key: "弹幕", Jar: png},
			{Key: "瓜子", Jar: png},
			{Key: "空", Jar: ""},
		},
	}
	got := JarSpecs(api)
	if len(got) != 2 || got[0] != root || got[1] != png {
		t.Fatalf("got %#v", got)
	}
}
