package spider

import (
	"os"
	"runtime"
	"strconv"
	"strings"
)

// scriptPoolSize 同站 JS/Python 并发 worker 数（多用户打同一站时可并行）。
// 可用环境变量 KOTV_SCRIPT_POOL 覆盖（1–32）。
func scriptPoolSize() int {
	if v := strings.TrimSpace(os.Getenv("KOTV_SCRIPT_POOL")); v != "" {
		if n, err := strconv.Atoi(v); err == nil && n >= 1 && n <= 32 {
			return n
		}
	}
	n := runtime.NumCPU()
	if n < 2 {
		n = 2
	}
	if n > 8 {
		n = 8
	}
	return n
}
