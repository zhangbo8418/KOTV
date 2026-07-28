package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/bobo/KOTV/internal/paths"
	"github.com/bobo/KOTV/internal/spider"
)

func main() {
	root := "/Users/bobo/Documents/GitHub/KOTV"
	_ = os.Setenv("KOTV_RUNTIME", filepath.Join(root, "dist/KOTV-macos-x64/runtime"))
	base := "https://tv.bobohome.store:20250/%F0%9F%96%A5PC%E4%B8%93%E7%94%A8/"
	fmt.Println("cache", paths.JsCache(), paths.PyCache())

	pyAPI := base + "py/%E6%98%9F%E8%8A%BD%E7%9F%AD%E5%89%A7.py"
	py := spider.Get("星芽短剧", pyAPI, "", "")
	defer py.Destroy()
	home, err := py.HomeContent(true)
	fmt.Println("PY home err=", err)
	fmt.Println("PY home=", truncate(home, 300))

	jsAPI := base + "js/drpy2.min.js"
	jsExt := base + "js/%E8%B7%AF%E6%BC%AB%E6%BC%AB.js"
	js := spider.Get("路漫漫", jsAPI, jsExt, "")
	defer js.Destroy()
	jsHome, err := js.HomeContent(true)
	fmt.Println("JS home err=", err)
	fmt.Println("JS home=", truncate(jsHome, 500))
}

func truncate(s string, n int) string {
	s = strings.ReplaceAll(s, "\n", " ")
	if len(s) > n {
		return s[:n] + "..."
	}
	return s
}
