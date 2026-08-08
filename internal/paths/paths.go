package paths

import (
	"os"
	"path/filepath"
	"runtime"
	"strings"
)

const appName = "KOTV"

// Root 返回用户数据根目录。
// Android：优先 KOTV_DATA_DIR / KOTV_CACHE_DIR（由 Flutter launcher 注入应用可写目录）。
//
// Windows 现用 %APPDATA%/KOTV；若仅有旧版 %APPDATA%/KOTV/cache 则继续用旧根，避免丢设置。
// 缓存统一落在 Root()/cache/...，不再出现 cache/data/cache 套娃。
func Root() string {
	if v := strings.TrimSpace(os.Getenv("KOTV_DATA_DIR")); v != "" {
		return ensure(v)
	}
	if v := strings.TrimSpace(os.Getenv("KOTV_CACHE_DIR")); v != "" {
		return ensure(v)
	}
	var base string
	switch runtime.GOOS {
	case "windows":
		base = os.Getenv("APPDATA")
		if base == "" {
			base = filepath.Join(os.Getenv("USERPROFILE"), "AppData", "Roaming")
		}
		preferred := filepath.Join(base, appName)
		legacy := filepath.Join(base, appName, "cache")
		// 旧安装：设置还在 …/KOTV/cache/setting.ini，且新根尚无设置 → 沿用旧根
		if fileExists(filepath.Join(legacy, "setting.ini")) && !fileExists(filepath.Join(preferred, "setting.ini")) {
			return ensure(legacy)
		}
		return ensure(preferred)
	case "darwin":
		home, _ := os.UserHomeDir()
		// 优先 Application Support；旧版把根放在 Caches 时继续兼容
		preferred := filepath.Join(home, "Library", "Application Support", appName)
		legacy := filepath.Join(home, "Library", "Caches", appName)
		if fileExists(filepath.Join(legacy, "setting.ini")) && !fileExists(filepath.Join(preferred, "setting.ini")) {
			return ensure(legacy)
		}
		return ensure(preferred)
	case "android":
		// 未注入环境变量时回落到 cwd（通常为应用私有目录）。
		cwd, _ := os.Getwd()
		if cwd != "" {
			return ensure(filepath.Join(cwd, "kotv-cache"))
		}
		return ensure(filepath.Join("/data/local/tmp", appName))
	default:
		home, _ := os.UserHomeDir()
		preferred := filepath.Join(home, ".local", "share", appName)
		legacy := filepath.Join(home, ".cache", appName)
		if fileExists(filepath.Join(legacy, "setting.ini")) && !fileExists(filepath.Join(preferred, "setting.ini")) {
			return ensure(legacy)
		}
		return ensure(preferred)
	}
}

func Data() string { return ensure(filepath.Join(Root(), "data")) }

// CacheRoot 所有可再生缓存的统一根：{Root}/cache
func CacheRoot() string { return ensure(filepath.Join(Root(), "cache")) }

// Assets 返回本地 assets 资源根，对应 bridge AssetManager 的 {root}/assets（供 assets:// 使用）。
func Assets() string  { return ensure(filepath.Join(Root(), "assets")) }
func DB() string      { return filepath.Join(ensure(filepath.Join(Root(), "db")), "tv.db") }
func Setting() string { return filepath.Join(ensure(Root()), "setting.ini") }

// 下列缓存均在 CacheRoot 下，与 bridge 的 Root/cache/* 对齐，避免 data/cache 再套一层。
func JarCache() string { return ensure(filepath.Join(CacheRoot(), "jar")) }
func PyCache() string  { return ensure(filepath.Join(CacheRoot(), "py")) }
func PicCache() string { return ensure(filepath.Join(CacheRoot(), "pic")) }
func LogDir() string   { return ensure(filepath.Join(Data(), "log")) }
func JsCache() string  { return ensure(filepath.Join(CacheRoot(), "js")) }
func EpgCache() string { return ensure(filepath.Join(CacheRoot(), "epg")) }
func HttpCache() string {
	return ensure(filepath.Join(CacheRoot(), "http"))
}
func SubCache() string { return ensure(filepath.Join(CacheRoot(), "sub")) }

// Ensure 确保目录存在并返回路径。
func Ensure(p string) string { return ensure(p) }

func JarPath(md5 string) string {
	return filepath.Join(JarCache(), md5+".jar")
}

func Downloads() string {
	home, _ := os.UserHomeDir()
	switch runtime.GOOS {
	case "windows":
		if p := os.Getenv("USERPROFILE"); p != "" {
			return ensure(filepath.Join(p, "Downloads"))
		}
	case "darwin", "linux":
		return ensure(filepath.Join(home, "Downloads"))
	}
	return ensure(filepath.Join(Root(), "downloads"))
}

func ensure(p string) string {
	_ = os.MkdirAll(p, 0o755)
	return p
}

func fileExists(p string) bool {
	st, err := os.Stat(p)
	return err == nil && !st.IsDir()
}
