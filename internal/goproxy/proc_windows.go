//go:build windows

package goproxy

import "syscall"

func hideWindowAttrs() *syscall.SysProcAttr {
	return &syscall.SysProcAttr{HideWindow: true}
}
