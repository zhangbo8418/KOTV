//go:build !windows

package spider

import "os/exec"

func setHiddenConsoleAttrs(*exec.Cmd) {}
