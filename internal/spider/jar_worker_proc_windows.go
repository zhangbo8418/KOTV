//go:build windows

package spider

import (
	"os/exec"
	"syscall"
)

// setHiddenConsoleAttrs 隐藏 Windows 控制台黑框（python.exe / java.exe 等子系统控制台程序）。
func setHiddenConsoleAttrs(cmd *exec.Cmd) {
	cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true}
}
