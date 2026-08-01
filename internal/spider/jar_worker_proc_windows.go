//go:build windows

package spider

import (
	"os"
	"os/exec"
	"strconv"
	"syscall"
)

// setChildProcAttrs 隐藏 Windows 控制台黑框（python.exe / java.exe 等子系统控制台程序）。
func setChildProcAttrs(cmd *exec.Cmd) {
	cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true}
}

// killProcessTree 用 taskkill /T 杀掉进程树（JVM 可能再拉子进程）。
func killProcessTree(proc *os.Process) {
	if proc == nil {
		return
	}
	_ = exec.Command("taskkill", "/F", "/T", "/PID", strconv.Itoa(proc.Pid)).Run()
	_ = proc.Kill()
}
