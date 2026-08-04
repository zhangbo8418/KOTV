package spider

import (
	"fmt"
	"log"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/bobo/KOTV/internal/paths"
)

var (
	jsLogMu   sync.Mutex
	jsLogFile *os.File
)

// jsLog 输出 JS 爬虫诊断日志：stderr（Flutter 可收）+ 落盘 LogDir/js-spider.log。
func jsLog(format string, args ...interface{}) {
	msg := fmt.Sprintf(format, args...)
	log.Print(msg)
	jsLogMu.Lock()
	defer jsLogMu.Unlock()
	f, err := jsLogFileLocked()
	if err != nil || f == nil {
		return
	}
	_, _ = fmt.Fprintf(f, "%s %s\n", time.Now().Format("2006-01-02 15:04:05.000"), msg)
	_ = f.Sync()
}

func jsLogFileLocked() (*os.File, error) {
	if jsLogFile != nil {
		return jsLogFile, nil
	}
	dir := paths.LogDir()
	_ = os.MkdirAll(dir, 0o755)
	path := filepath.Join(dir, "js-spider.log")
	f, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
	if err != nil {
		return nil, err
	}
	jsLogFile = f
	_, _ = fmt.Fprintf(f, "---- js-spider log opened %s ----\n", time.Now().Format(time.RFC3339))
	return f, nil
}

func jsPreview(s string, max int) string {
	s = strings.TrimSpace(s)
	if max <= 0 {
		max = 240
	}
	if len(s) <= max {
		return s
	}
	return s[:max] + fmt.Sprintf("…(%d bytes)", len(s))
}
