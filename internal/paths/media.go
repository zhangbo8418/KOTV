package paths

import (
	"os"
	"path/filepath"
	"strings"
)

// MediaRoots 本机媒体 / 局域网 /file 允许访问的根目录。
func MediaRoots() []string {
	return []string{Downloads(), Data()}
}

// UnderMediaRoot 判断路径是否落在允许的媒体根下。
func UnderMediaRoot(p string) bool {
	abs, err := filepath.Abs(filepath.Clean(p))
	if err != nil {
		return false
	}
	for _, root := range MediaRoots() {
		r, err := filepath.Abs(root)
		if err != nil {
			continue
		}
		if abs == r || strings.HasPrefix(abs, r+string(os.PathSeparator)) {
			return true
		}
	}
	return false
}

// ResolveMediaPath 解析 /file 相对或绝对路径；越界返回空。
func ResolveMediaPath(raw string) string {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return ""
	}
	name := filepath.FromSlash(raw)
	if !filepath.IsAbs(name) {
		name = filepath.Clean(filepath.Join(Data(), name))
	} else {
		name = filepath.Clean(name)
	}
	if !UnderMediaRoot(name) {
		return ""
	}
	return name
}
