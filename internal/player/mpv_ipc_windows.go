//go:build windows

package player

import (
	"errors"
	"fmt"
	"os"
	"time"

	"golang.org/x/sys/windows"
)

// MPV 在 Windows 使用命名管道；所用 CreateFileW/CloseHandle 均为 Win7 原生 API。
func mpvNewIPCPath() string {
	return fmt.Sprintf(`\\.\pipe\kotv-mpv-%d-%d`, os.Getpid(), time.Now().UnixNano())
}

// Windows 命名管道不是文件，服务端进程退出后由系统自动回收。
func mpvCleanupIPC(string) {}

// Windows 的 \\.\pipe 路径不能可靠地用 os.Stat 判断；查询函数自身会限时重试连接。
func mpvIPCReady(string) bool { return true }

func mpvIPCGetTime(path string) (pos, dur float64) {
	name, err := windows.UTF16PtrFromString(path)
	if err != nil {
		return -1, 0
	}

	// MPV 创建管道存在短暂竞态；只在后台轮询 goroutine 中等待，最长 1 秒。
	deadline := time.Now().Add(time.Second)
	var handle windows.Handle
	for {
		handle, err = windows.CreateFile(
			name,
			windows.GENERIC_READ|windows.GENERIC_WRITE,
			0,
			nil,
			windows.OPEN_EXISTING,
			0,
			0,
		)
		if err == nil {
			break
		}
		if (!errors.Is(err, windows.ERROR_PIPE_BUSY) &&
			!errors.Is(err, windows.ERROR_FILE_NOT_FOUND)) ||
			time.Now().After(deadline) {
			return -1, 0
		}
		time.Sleep(50 * time.Millisecond)
	}

	pipe := os.NewFile(uintptr(handle), path)
	if pipe == nil {
		_ = windows.CloseHandle(handle)
		return -1, 0
	}
	defer pipe.Close()

	// 防止异常 MPV 永久占住进度轮询。Stop/换集不等待本次 IPC 查询。
	timer := time.AfterFunc(time.Second, func() { _ = pipe.Close() })
	defer timer.Stop()
	return mpvQueryTime(pipe)
}
