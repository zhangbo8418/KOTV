package cacheclean

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/bobo/KOTV/internal/paths"
)

// LogFileInfo 日志目录内单个文件摘要。
type LogFileInfo struct {
	Name    string `json:"name"`
	Size    int64  `json:"size"`
	ModTime int64  `json:"modTime"` // unix 秒
}

// logPath 仅允许 LogDir 下的纯文件名，拒绝路径穿越。
func logPath(name string) (string, error) {
	name = strings.TrimSpace(name)
	base := filepath.Base(name)
	if name == "" || base != name || name == "." || name == ".." {
		return "", fmt.Errorf("非法日志名")
	}
	dir := filepath.Clean(paths.LogDir())
	full := filepath.Clean(filepath.Join(dir, name))
	rel, err := filepath.Rel(dir, full)
	if err != nil || rel == ".." || strings.HasPrefix(rel, ".."+string(os.PathSeparator)) {
		return "", fmt.Errorf("非法日志名")
	}
	return full, nil
}

// ListLogs 列出引擎日志目录中的文件。
func ListLogs() ([]LogFileInfo, error) {
	dir := paths.LogDir()
	_ = os.MkdirAll(dir, 0o755)
	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil, err
	}
	out := make([]LogFileInfo, 0, len(entries))
	for _, e := range entries {
		if e.IsDir() {
			continue
		}
		info, err := e.Info()
		if err != nil {
			continue
		}
		out = append(out, LogFileInfo{
			Name:    e.Name(),
			Size:    info.Size(),
			ModTime: info.ModTime().Unix(),
		})
	}
	return out, nil
}

// ReadLogTail 读取日志文件末尾最多 maxBytes 字节（默认 128KiB，上限 1MiB）。
func ReadLogTail(name string, maxBytes int64) (content string, size int64, err error) {
	if maxBytes <= 0 {
		maxBytes = 128 << 10
	}
	if maxBytes > 1<<20 {
		maxBytes = 1 << 20
	}
	p, err := logPath(name)
	if err != nil {
		return "", 0, err
	}
	f, err := os.Open(p)
	if err != nil {
		return "", 0, err
	}
	defer f.Close()
	st, err := f.Stat()
	if err != nil {
		return "", 0, err
	}
	size = st.Size()
	start := int64(0)
	if size > maxBytes {
		start = size - maxBytes
	}
	if _, err := f.Seek(start, 0); err != nil {
		return "", size, err
	}
	buf := make([]byte, size-start)
	n, err := f.Read(buf)
	if err != nil && n == 0 {
		return "", size, err
	}
	text := string(buf[:n])
	if start > 0 {
		text = "…（前文已省略）\n" + text
	}
	return text, size, nil
}

// ClearLogs 截断/清理 LogDir（与清理缓存「仅日志」同一实现）。
func ClearLogs() (freed int64, err error) {
	return clearLogs(paths.LogDir())
}

// ClearLogFile 截断单个日志文件；文件不存在视为已清空。
func ClearLogFile(name string) (freed int64, err error) {
	p, err := logPath(name)
	if err != nil {
		return 0, err
	}
	st, err := os.Stat(p)
	if err != nil {
		if os.IsNotExist(err) {
			return 0, nil
		}
		return 0, err
	}
	sz := st.Size()
	if err := truncateFile(p); err != nil {
		return 0, err
	}
	_ = os.Chtimes(p, time.Now(), time.Now())
	return sz, nil
}
