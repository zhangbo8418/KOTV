//go:build !windows

package player

import (
	"fmt"
	"net"
	"os"
	"path/filepath"
	"time"
)

func mpvNewIPCPath() string {
	return filepath.Join(os.TempDir(), fmt.Sprintf("kotv-mpv-%d-%d.sock", os.Getpid(), time.Now().UnixNano()))
}

func mpvCleanupIPC(path string) {
	if path != "" {
		_ = os.Remove(path)
	}
}

func mpvIPCReady(path string) bool {
	_, err := os.Stat(path)
	return err == nil
}

func mpvIPCGetTime(path string) (pos, dur float64) {
	conn, err := net.DialTimeout("unix", path, time.Second)
	if err != nil {
		return -1, 0
	}
	defer conn.Close()
	_ = conn.SetDeadline(time.Now().Add(time.Second))
	return mpvQueryTime(conn)
}
