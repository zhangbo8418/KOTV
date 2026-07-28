package paths

import (
	"os"
	"path/filepath"
	"runtime"
)

const appName = "KOTV"

// Root 返回用户数据根目录。
func Root() string {
	var base string
	switch runtime.GOOS {
	case "windows":
		base = os.Getenv("APPDATA")
		if base == "" {
			base = filepath.Join(os.Getenv("USERPROFILE"), "AppData", "Roaming")
		}
		return filepath.Join(base, appName, "cache")
	case "darwin":
		home, _ := os.UserHomeDir()
		return filepath.Join(home, "Library", "Caches", appName)
	default:
		home, _ := os.UserHomeDir()
		return filepath.Join(home, ".cache", appName)
	}
}

func Data() string  { return ensure(filepath.Join(Root(), "data")) }

// Assets 返回本地 assets 资源根，对应 bridge AssetManager 的 {root}/assets（供 assets:// 使用）。
func Assets() string { return ensure(filepath.Join(Root(), "assets")) }
func DB() string    { return filepath.Join(ensure(filepath.Join(Root(), "db")), "tv.db") }
func Setting() string { return filepath.Join(ensure(Root()), "setting.ini") }
func JarCache() string { return ensure(filepath.Join(Data(), "cache", "jar")) }
func PyCache() string  { return ensure(filepath.Join(Data(), "cache", "py")) }
func PicCache() string { return ensure(filepath.Join(Data(), "cache", "pic")) }
func LogDir() string   { return ensure(filepath.Join(Data(), "log")) }
func JsCache() string  { return ensure(filepath.Join(Data(), "cache", "js")) } // local 键值等；远程 JS 模块在内存
func EpgCache() string { return ensure(filepath.Join(Data(), "cache", "epg")) }

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
