//go:build !windows && !linux

package spider

import (
	"os"
	"os/exec"
)

func setChildProcAttrs(*exec.Cmd) {}

func killProcessTree(proc *os.Process) {
	if proc == nil {
		return
	}
	_ = proc.Kill()
}
