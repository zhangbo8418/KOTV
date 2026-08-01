package runtime

import (
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
)

// 平台标识（用于下载键、提示信息等）。
func Platform() string {
	goos, arch := runtime.GOOS, runtime.GOARCH
	switch goos {
	case "darwin":
		if arch == "arm64" {
			return "macos-arm64"
		}
		return "macos-x64"
	case "windows":
		if arch == "arm64" {
			return "windows-arm64"
		}
		return "windows-x64"
	case "linux":
		if arch == "arm64" {
			return "linux-arm64"
		}
		return "linux-x64"
	default:
		return goos + "-" + arch
	}
}

var (
	mu       sync.RWMutex
	baseDirs []string
)

// SetBaseDirs 覆盖搜索根（测试用）。
func SetBaseDirs(dirs ...string) {
	mu.Lock()
	baseDirs = append([]string{}, dirs...)
	mu.Unlock()
}

// Roots 返回 runtime 搜索根目录列表。
func Roots() []string {
	mu.RLock()
	if len(baseDirs) > 0 {
		out := append([]string{}, baseDirs...)
		mu.RUnlock()
		return out
	}
	mu.RUnlock()

	var roots []string
	plat := Platform()

	// 1) 可执行文件旁：./runtime
	if exe, err := os.Executable(); err == nil {
		if real, err2 := filepath.EvalSymlinks(exe); err2 == nil {
			exe = real
		}
		dir := filepath.Dir(exe)
		roots = append(roots,
			filepath.Join(dir, "runtime"),
			dir,
			// MacOS → ../Resources/runtime；Resources/engine → ../runtime
			filepath.Clean(filepath.Join(dir, "..", "runtime")),
			filepath.Clean(filepath.Join(dir, "..", "Resources", "runtime")),
		)
		// macOS .app：向上找到 Contents，再取 Resources/runtime
		if runtime.GOOS == "darwin" {
			p := dir
			for i := 0; i < 6; i++ {
				if filepath.Base(p) == "Contents" {
					roots = append(roots, filepath.Join(p, "Resources", "runtime"))
					break
				}
				next := filepath.Dir(p)
				if next == p {
					break
				}
				p = next
			}
		}
		// 启动脚本把引擎拷到 /tmp 时写入旁路标记
		if b, err := os.ReadFile(exe + ".runtime"); err == nil {
			if p := strings.TrimSpace(string(b)); p != "" {
				roots = append([]string{p}, roots...)
			}
		}
	}

	// 2) 环境变量（优先）
	if p := os.Getenv("KOTV_RUNTIME"); p != "" {
		roots = append([]string{p}, roots...)
	}

	// 3) 开发态：仓库内 runtime/
	if cwd, err := os.Getwd(); err == nil {
		roots = append(roots,
			filepath.Join(cwd, "runtime"),
			filepath.Join(cwd, "dist", "runtime"),
			filepath.Join(cwd, "dist", "KOTV-"+plat, "runtime"),
		)
	}

	return uniqueExistingParents(roots)
}

func uniqueExistingParents(in []string) []string {
	seen := map[string]bool{}
	var out []string
	for _, p := range in {
		if p == "" || seen[p] {
			continue
		}
		seen[p] = true
		out = append(out, p)
	}
	return out
}

func firstExisting(candidates ...string) string {
	for _, c := range candidates {
		if c == "" {
			continue
		}
		if st, err := os.Stat(c); err == nil && !st.IsDir() {
			_ = os.Chmod(c, 0o755)
			return c
		}
	}
	return ""
}

func underRoots(rel ...string) []string {
	var out []string
	for _, root := range Roots() {
		for _, r := range rel {
			out = append(out, filepath.Join(root, r))
		}
	}
	return out
}

// Java 返回捆绑 JRE 中的 java（不回落系统 JAVA_HOME / PATH）。
func Java() string {
	return firstExisting(underRoots(
		filepath.Join("jre", "bin", "java"),
		filepath.Join("jre", "bin", "java.exe"),
		filepath.Join("jre", "Contents", "Home", "bin", "java"), // macOS Temurin 布局
	)...)
}

// JVMLib 返回进程内执行 JAR 所需的捆绑 JVM 动态库。
func JVMLib() string {
	return firstExisting(underRoots(
		filepath.Join("jre", "bin", "server", "jvm.dll"),
		filepath.Join("jre", "lib", "server", "libjvm.dylib"),
		filepath.Join("jre", "lib", "server", "libjvm.so"),
		filepath.Join("jre", "Contents", "Home", "lib", "server", "libjvm.dylib"),
	)...)
}

// Python 返回捆绑 Python（不回落系统 PATH）。
func Python() string {
	return firstExisting(underRoots(
		filepath.Join("python", "bin", "python3"),
		filepath.Join("python", "bin", "python"),
		filepath.Join("python", "python.exe"),
		filepath.Join("python", "python3.exe"),
		filepath.Join("python", "python3"),
		filepath.Join("python", "python"),
	)...)
}

// Chromium 返回 Chrome / chrome-headless-shell 路径（捆绑优先）。
func Chromium() string {
	cands := underRoots(
		filepath.Join("chromium", "chrome-headless-shell"),
		filepath.Join("chromium", "chrome-headless-shell.exe"),
		filepath.Join("chromium", "chrome.exe"),
		filepath.Join("chromium", "chrome"),
		filepath.Join("chromium", "Google Chrome for Testing.app", "Contents", "MacOS", "Google Chrome for Testing"),
		filepath.Join("chromium", "Chromium.app", "Contents", "MacOS", "Chromium"),
		filepath.Join("chrome", "chrome"),
		filepath.Join("chrome", "chrome.exe"),
	)
	if p := firstExisting(cands...); p != "" {
		return p
	}
	// 系统 Chrome
	switch runtime.GOOS {
	case "darwin":
		for _, p := range []string{
			"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
			"/Applications/Chromium.app/Contents/MacOS/Chromium",
			"/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge",
		} {
			if firstExisting(p) != "" {
				return p
			}
		}
	case "windows":
		for _, p := range []string{
			filepath.Join(os.Getenv("ProgramFiles"), "Google", "Chrome", "Application", "chrome.exe"),
			filepath.Join(os.Getenv("ProgramFiles(x86)"), "Google", "Chrome", "Application", "chrome.exe"),
			filepath.Join(os.Getenv("ProgramFiles"), "Microsoft", "Edge", "Application", "msedge.exe"),
		} {
			if firstExisting(p) != "" {
				return p
			}
		}
	}
	for _, name := range []string{"google-chrome", "chromium", "chromium-browser", "chrome"} {
		if p, err := exec.LookPath(name); err == nil {
			return p
		}
	}
	return ""
}

// FFmpeg 返回 ffmpeg 路径。
func FFmpeg() string {
	cands := underRoots(
		filepath.Join("ffmpeg", "ffmpeg"),
		filepath.Join("ffmpeg", "ffmpeg.exe"),
		filepath.Join("ffmpeg", "bin", "ffmpeg"),
		filepath.Join("ffmpeg", "bin", "ffmpeg.exe"),
	)
	if p := firstExisting(cands...); p != "" {
		return p
	}
	if p, err := exec.LookPath("ffmpeg"); err == nil {
		return p
	}
	return ""
}

// LibVLC 返回页内 VLC 所需的 libvlc 目录（同级含 plugins/ 子目录）。
func LibVLC() string {
	cands := underRoots(
		filepath.Join("libvlc", "libvlc.dylib"),
		filepath.Join("libvlc", "libvlc.5.dylib"),
		filepath.Join("libvlc", "libvlc.dll"),
		filepath.Join("libvlc", "libvlc.so"),
		filepath.Join("libvlc", "libvlc.so.5"),
		// 旧布局
		filepath.Join("vlc", "VLC.app", "Contents", "MacOS", "lib", "libvlc.dylib"),
		filepath.Join("vlc", "libvlc.dll"),
	)
	if p := firstExisting(cands...); p != "" {
		return filepath.Dir(p)
	}
	return ""
}

// VLC 返回捆绑或系统 VLC 可执行文件（外部播放；页内嵌入用 LibVLC）。
func VLC() string {
	cands := underRoots(
		filepath.Join("vlc", "VLC.app", "Contents", "MacOS", "VLC"),
		filepath.Join("vlc", "vlc.exe"),
		filepath.Join("vlc", "vlc"),
		filepath.Join("vlc", "bin", "vlc"),
		filepath.Join("lib", "vlc.exe"), // Windows 部分原生库布局
		filepath.Join("lib", "vlc"),
	)
	if p := firstExisting(cands...); p != "" {
		return p
	}
	switch runtime.GOOS {
	case "darwin":
		if p := firstExisting("/Applications/VLC.app/Contents/MacOS/VLC"); p != "" {
			return p
		}
	case "windows":
		for _, base := range []string{os.Getenv("ProgramFiles"), os.Getenv("ProgramFiles(x86)")} {
			if p := firstExisting(filepath.Join(base, "VideoLAN", "VLC", "vlc.exe")); p != "" {
				return p
			}
		}
	}
	if p, err := exec.LookPath("vlc"); err == nil {
		return p
	}
	return ""
}

// MPV 返回外部 mpv 可执行文件（发行包不捆绑；回落 PATH / 系统安装）。
func MPV() string {
	cands := underRoots(
		filepath.Join("mpv", "mpv"),
		filepath.Join("mpv", "mpv.exe"),
		filepath.Join("mpv", "mpv.app", "Contents", "MacOS", "mpv"),
		filepath.Join("mpv", "bin", "mpv"),
	)
	if p := firstExisting(cands...); p != "" {
		return p
	}
	if p, err := exec.LookPath("mpv"); err == nil {
		return p
	}
	return ""
}

// LibMPV 返回页内 MPV 所需的动态库；它与 mpv 可执行文件是不同产物。
func LibMPV() string {
	cands := underRoots(
		filepath.Join("libmpv", "libmpv.dylib"),
		filepath.Join("libmpv", "libmpv.so"),
		filepath.Join("libmpv", "libmpv.so.2"),
		filepath.Join("libmpv", "libmpv-2.dll"),
		filepath.Join("libmpv", "mpv-2.dll"),
		filepath.Join("mpv", "libmpv.dylib"),
		filepath.Join("mpv", "libmpv-2.dll"),
	)
	return firstExisting(cands...)
}

// BridgeJAR 返回 spider-bridge.jar。
func BridgeJAR() string {
	cands := underRoots(
		filepath.Join("bridge", "spider-bridge.jar"),
		"spider-bridge.jar",
	)
	cands = append(cands, "bridge/spider-bridge.jar", "spider-bridge.jar")
	if exe, err := os.Executable(); err == nil {
		dir := filepath.Dir(exe)
		cands = append(cands,
			filepath.Join(dir, "bridge", "spider-bridge.jar"),
			filepath.Join(dir, "spider-bridge.jar"),
		)
	}
	return firstExisting(cands...)
}

// Status 汇总捆绑/系统运行时状态（不含 jvm；mpv/vlc 由客户端排到末尾展示）。
func Status() map[string]string {
	return map[string]string{
		"platform": Platform(),
		"java":     orMissing(Java()),
		"python":   orMissing(Python()),
		"chromium": orMissing(Chromium()),
		"ffmpeg":   orMissing(FFmpeg()),
		"libvlc":   orMissing(LibVLC()),
		"bridge":   orMissing(BridgeJAR()),
		"quickjs":  "embedded(CGO)",
		"mpv":      orMissing(MPV()),
		"vlc":      orMissing(VLC()),
	}
}

func orMissing(p string) string {
	if p == "" {
		return "(missing)"
	}
	return p
}
