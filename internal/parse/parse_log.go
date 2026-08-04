package parse

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
	parseLogMu   sync.Mutex
	parseLogFile *os.File
)

// parseLog 二次解析诊断：stderr + LogDir/parse.log（对齐 TV ParseJob/SpiderDebug 用途）。
func parseLog(format string, args ...interface{}) {
	msg := fmt.Sprintf(format, args...)
	log.Print(msg)
	parseLogMu.Lock()
	defer parseLogMu.Unlock()
	f, err := parseLogFileLocked()
	if err != nil || f == nil {
		return
	}
	_, _ = fmt.Fprintf(f, "%s %s\n", time.Now().Format("2006-01-02 15:04:05.000"), msg)
	_ = f.Sync()
}

func parseLogFileLocked() (*os.File, error) {
	if parseLogFile != nil {
		return parseLogFile, nil
	}
	dir := paths.LogDir()
	_ = os.MkdirAll(dir, 0o755)
	path := filepath.Join(dir, "parse.log")
	f, err := os.OpenFile(path, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
	if err != nil {
		return nil, err
	}
	parseLogFile = f
	_, _ = fmt.Fprintf(f, "---- parse log opened %s ----\n", time.Now().Format(time.RFC3339))
	return f, nil
}

func parsePreview(s string, max int) string {
	s = strings.TrimSpace(s)
	if max <= 0 {
		max = 240
	}
	if len(s) <= max {
		return s
	}
	return s[:max] + fmt.Sprintf("…(%d bytes)", len(s))
}
