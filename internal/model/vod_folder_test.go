package model

import "testing"

func TestIsFolder(t *testing.T) {
	cases := []struct {
		name string
		vod  Vod
		want bool
	}{
		{name: "folder tag", vod: Vod{VodTag: "folder"}, want: true},
		{name: "FOLDER ignore case", vod: Vod{VodTag: "FOLDER"}, want: true},
		{name: "file alone", vod: Vod{VodTag: "file"}, want: false},
		{name: "file with cate", vod: Vod{VodTag: "file", Cate: FlexString(`{"land":1}`)}, want: true},
		{name: "cate only", vod: Vod{Cate: FlexString(`{"land":1}`)}, want: true},
		{name: "empty", vod: Vod{}, want: false},
	}
	for _, c := range cases {
		if got := c.vod.IsFolder(); got != c.want {
			t.Fatalf("%s: IsFolder()=%v want %v", c.name, got, c.want)
		}
	}
}
