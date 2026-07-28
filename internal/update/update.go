package update

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"

	"github.com/bobo/KOTV/internal/paths"
	"github.com/bobo/KOTV/internal/util"
)

// CurrentVersion 可由 CI 通过
// -ldflags "-X github.com/bobo/KOTV/internal/update.CurrentVersion=1.2.3" 注入。
var CurrentVersion = "0.1.0"

// Info 远程版本信息。
type Info struct {
	Version     string            `json:"version"`
	Notes       string            `json:"notes"`
	Downloads   map[string]string `json:"downloads"`
	VersionURL  string            `json:"-"`
}

// DefaultVersionURL 默认 version.json 地址（可被设置覆盖）。
const DefaultVersionURL = ""

// Check 检查更新。versionURL 为空则跳过。
func Check(versionURL string) (*Info, error) {
	if strings.TrimSpace(versionURL) == "" {
		return nil, fmt.Errorf("未配置更新地址")
	}
	body, err := util.HTTPGet(versionURL, nil)
	if err != nil {
		return nil, err
	}
	var info Info
	if err := json.Unmarshal([]byte(body), &info); err != nil {
		return nil, err
	}
	info.VersionURL = versionURL
	if !IsNewer(info.Version, CurrentVersion) {
		return nil, nil
	}
	return &info, nil
}

// IsNewer 简单 semver 比较（x.y.z）。
func IsNewer(remote, local string) bool {
	rp := splitVer(remote)
	lp := splitVer(local)
	for i := 0; i < 3; i++ {
		if rp[i] > lp[i] {
			return true
		}
		if rp[i] < lp[i] {
			return false
		}
	}
	return false
}

func splitVer(v string) [3]int {
	v = strings.TrimPrefix(strings.TrimSpace(v), "v")
	parts := strings.Split(v, ".")
	var out [3]int
	for i := 0; i < 3 && i < len(parts); i++ {
		fmt.Sscanf(parts[i], "%d", &out[i])
	}
	return out
}

// PlatformKey 当前平台下载键。
func PlatformKey() string {
	goos := runtime.GOOS
	arch := runtime.GOARCH
	switch goos {
	case "darwin":
		if arch == "arm64" {
			return "darwin-arm64"
		}
		return "darwin-amd64"
	case "windows":
		if arch == "arm64" {
			return "windows-arm64"
		}
		return "windows-amd64"
	default:
		return "linux-amd64"
	}
}

// DownloadAndApply 下载 zip 并拉起 updater。
func DownloadAndApply(info *Info) error {
	if info == nil {
		return fmt.Errorf("无更新信息")
	}
	key := PlatformKey()
	dl := info.Downloads[key]
	if dl == "" {
		dl = info.Downloads[runtime.GOOS]
	}
	if dl == "" {
		return fmt.Errorf("无适合当前平台的下载: %s", key)
	}
	dest := filepath.Join(paths.Ensure(filepath.Join(paths.Root(), "update")), "update.zip")
	if err := downloadFile(dl, dest); err != nil {
		return err
	}
	exe, err := os.Executable()
	if err != nil {
		return err
	}
	appDir := filepath.Dir(exe)
	updater := findUpdater(appDir)
	if updater == "" {
		return fmt.Errorf("未找到 updater，请将 updater 放在程序同目录")
	}
	cmd := exec.Command(updater, "-path", appDir, "-file", dest)
	if err := cmd.Start(); err != nil {
		return err
	}
	return nil
}

func downloadFile(url, dest string) error {
	resp, err := http.Get(url)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode >= 400 {
		return fmt.Errorf("下载失败: %s", resp.Status)
	}
	f, err := os.Create(dest)
	if err != nil {
		return err
	}
	defer f.Close()
	_, err = io.Copy(f, resp.Body)
	return err
}

func findUpdater(appDir string) string {
	names := []string{"updater", "updater.exe", "KOTV-updater", "KOTV-updater.exe"}
	for _, n := range names {
		p := filepath.Join(appDir, n)
		if st, err := os.Stat(p); err == nil && !st.IsDir() {
			return p
		}
	}
	// 开发态：cmd/updater
	dev := filepath.Join(appDir, "cmd", "updater", "updater")
	if st, err := os.Stat(dev); err == nil && !st.IsDir() {
		return dev
	}
	return ""
}
