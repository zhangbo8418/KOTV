//go:build linux

package spider

import (
	"os"
	"os/exec"
	"syscall"
)

// setChildProcAttrs：父进程（引擎）被硬杀时，子进程随 Pdeathsig 退出，避免 JRE/Python 孤儿。
func setChildProcAttrs(cmd *exec.Cmd) {
	cmd.SysProcAttr = &syscall.SysProcAttr{Pdeathsig: syscall.SIGKILL}
}

func killProcessTree(proc *os.Process) {
	if proc == nil {
		return
	}
	// 尽力杀同组（若曾 Setpgid）+ 本进程。
	_ = syscall.Kill(-proc.Pid, syscall.SIGKILL)
	_ = proc.Kill()
}
