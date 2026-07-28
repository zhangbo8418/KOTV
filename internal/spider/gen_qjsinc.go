//go:build ignore

package main

import (
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

// 生成 internal/spider/qjsinc（复制 quickjs-go 头文件），供 CGO ModuleLoader 使用。
// 不入库（见 .gitignore）；由 scripts/package.sh / go generate 在构建前生成。
func main() {
	// 先 download，避免 list 时 stderr 进度干扰；再用 Output() 只取 Dir。
	// 切勿 CombinedOutput：会把 "go: downloading …" 拼进路径。
	if out, err := exec.Command("go", "mod", "download", "github.com/buke/quickjs-go").CombinedOutput(); err != nil {
		fmt.Fprintf(os.Stderr, "go mod download quickjs-go: %v\n%s\n", err, out)
		os.Exit(1)
	}
	out, err := exec.Command("go", "list", "-f", "{{.Dir}}", "github.com/buke/quickjs-go").Output()
	if err != nil {
		fmt.Fprintf(os.Stderr, "go list quickjs-go: %v\n%s\n", err, out)
		os.Exit(1)
	}
	qdir := string(bytesTrim(out))
	if qdir == "" || strings.Contains(qdir, "\n") {
		fmt.Fprintf(os.Stderr, "go list quickjs-go: bad Dir %q\n", qdir)
		os.Exit(1)
	}
	bridge := filepath.Join(qdir, "bridge.h")
	if _, err := os.Stat(bridge); err != nil {
		fmt.Fprintf(os.Stderr, "missing %s: %v\n", bridge, err)
		os.Exit(1)
	}
	quickjs := filepath.Join(qdir, "deps", "quickjs")
	if st, err := os.Stat(quickjs); err != nil || !st.IsDir() {
		fmt.Fprintf(os.Stderr, "missing quickjs headers dir %s: %v\n", quickjs, err)
		os.Exit(1)
	}

	root, err := os.Getwd()
	if err != nil {
		panic(err)
	}
	inc := filepath.Join(root, "qjsinc")
	_ = os.RemoveAll(inc)
	if err := os.MkdirAll(inc, 0o755); err != nil {
		panic(err)
	}
	// 复制而非 symlink：CI/跨机器模块缓存路径不同，且 Windows 对 symlink 不友好。
	mustCopyFile(bridge, filepath.Join(inc, "bridge.h"))
	mustCopyDir(quickjs, filepath.Join(inc, "quickjs"))
	fmt.Println("qjsinc <-", qdir)
}

func mustCopyFile(src, dst string) {
	in, err := os.Open(src)
	if err != nil {
		panic(fmt.Errorf("open %s: %w", src, err))
	}
	defer in.Close()
	if err := os.MkdirAll(filepath.Dir(dst), 0o755); err != nil {
		panic(err)
	}
	out, err := os.OpenFile(dst, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o644)
	if err != nil {
		panic(err)
	}
	defer out.Close()
	if _, err := io.Copy(out, in); err != nil {
		panic(err)
	}
}

func mustCopyDir(src, dst string) {
	err := filepath.Walk(src, func(path string, info os.FileInfo, err error) error {
		if err != nil {
			return err
		}
		rel, err := filepath.Rel(src, path)
		if err != nil {
			return err
		}
		target := filepath.Join(dst, rel)
		if info.IsDir() {
			return os.MkdirAll(target, 0o755)
		}
		// CGO 只需头文件
		if filepath.Ext(path) != ".h" {
			return nil
		}
		mustCopyFile(path, target)
		return nil
	})
	if err != nil {
		panic(err)
	}
}

func bytesTrim(b []byte) []byte {
	i, j := 0, len(b)
	for i < j && (b[i] == ' ' || b[i] == '\n' || b[i] == '\r' || b[i] == '\t') {
		i++
	}
	for j > i && (b[j-1] == ' ' || b[j-1] == '\n' || b[j-1] == '\r' || b[j-1] == '\t') {
		j--
	}
	return b[i:j]
}
