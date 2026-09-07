package paths

import (
	"os"
	"path/filepath"
	"runtime"
	"strings"
)

// MediaRoots 本机 /file 优先查找的根（外部存储根 + 应用数据目录）。
func MediaRoots() []string {
	roots := []string{Downloads(), Data(), Root()}
	if ext := externalStorageRoot(); ext != "" {
		roots = append(roots, ext)
	}
	if v := strings.TrimSpace(os.Getenv("KOTV_CACHE_DIR")); v != "" {
		roots = append(roots, v)
	}
	return roots
}

func externalStorageRoot() string {
	// Android：常见外部存储（Environment.getExternalStorageDirectory()）
	if runtime.GOOS == "android" {
		for _, p := range []string{"/storage/emulated/0", "/sdcard"} {
			if st, err := os.Stat(p); err == nil && st.IsDir() {
				return p
			}
		}
	}
	return ""
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

// ResolveMediaPath 
// 1) 相对路径拼到 MediaRoots；
// 2) 绝对路径若存在则直接允许（本地仓 / jar / py / js 同目录相对脚本依赖此回退）；
// 3) /file/ 代理经 URL 清洗后常丢掉绝对路径前导 /（/file//storage/... → storage/...），此处还原。
func ResolveMediaPath(raw string) string {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return ""
	}
	raw = strings.TrimPrefix(raw, "file://")
	raw = strings.TrimPrefix(raw, "file:/")
	name := filepath.FromSlash(raw)
	name = filepath.Clean(name)

	if filepath.IsAbs(name) {
		if st, err := os.Stat(name); err == nil && (st.IsDir() || st.Mode().IsRegular()) {
			return name
		}
		return ""
	}

	// http://127.0.0.1/file//storage/emulated/0/... 被清洗成 storage/emulated/0/...
	if restored := filepath.Clean(string(os.PathSeparator) + name); filepath.IsAbs(restored) && len(restored) > 1 {
		if st, err := os.Stat(restored); err == nil && (st.IsDir() || st.Mode().IsRegular()) {
			return restored
		}
	}

	for _, root := range MediaRoots() {
		cand := filepath.Clean(filepath.Join(root, name))
		if st, err := os.Stat(cand); err == nil && (st.IsDir() || st.Mode().IsRegular()) {
			return cand
		}
	}
	return ""
}
