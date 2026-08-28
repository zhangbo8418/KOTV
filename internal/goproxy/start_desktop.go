//go:build !android

package goproxy

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"

	"github.com/bobo/KOTV/internal/paths"
)

const minSidecarBytes = 64 * 1024

func startSidecarPlatform() error {
	bin, err := resolveBinary()
	if err != nil {
		return err
	}
	stopExisting(filepath.Base(bin))
	cmd := exec.Command(bin)
	cmd.Dir = filepath.Dir(bin)
	if runtime.GOOS == "windows" {
		cmd.SysProcAttr = hideWindowAttrs()
	}
	if err := cmd.Start(); err != nil {
		return fmt.Errorf("exec go sidecar: %w", err)
	}
	return nil
}

func resolveBinary() (string, error) {
	names := []string{"go_proxy_video", "go-proxy", "proxy_video", "go_proxy"}
	dirs := []string{
		filepath.Join(paths.Root(), "files", "so"),
		filepath.Join(paths.Root(), "files"),
		paths.CacheRoot(),
		filepath.Join(paths.CacheRoot(), "so"),
	}
	for _, dir := range dirs {
		for _, name := range names {
			p := filepath.Join(dir, name)
			if ok, err := prepareBinary(p); ok {
				return p, nil
			} else if err != nil {
				continue
			}
		}
		if st, err := os.Stat(dir); err == nil && st.IsDir() {
			if p := largestFile(dir, minSidecarBytes); p != "" {
				if ok, _ := prepareBinary(p); ok {
					return p, nil
				}
			}
		}
	}
	return "", fmt.Errorf("go sidecar binary not found under %v", dirs)
}

func prepareBinary(p string) (bool, error) {
	st, err := os.Stat(p)
	if err != nil || st.IsDir() || st.Size() < minSidecarBytes {
		return false, err
	}
	if runtime.GOOS != "windows" {
		_ = os.Chmod(p, 0o755)
	}
	return true, nil
}

func largestFile(dir string, minSize int64) string {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return ""
	}
	var best string
	var size int64
	for _, e := range entries {
		if e.IsDir() {
			continue
		}
		info, err := e.Info()
		if err != nil || info.Size() < minSize {
			continue
		}
		if info.Size() > size {
			size = info.Size()
			best = filepath.Join(dir, e.Name())
		}
	}
	return best
}

func stopExisting(name string) {
	if name == "" {
		return
	}
	switch runtime.GOOS {
	case "windows":
		_ = exec.Command("taskkill", "/F", "/IM", name+".exe").Run()
	default:
		_ = exec.Command("pkill", "-f", name).Run()
	}
}
