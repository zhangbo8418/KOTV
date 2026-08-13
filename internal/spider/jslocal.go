package spider

import (
	"encoding/base64"
	"os"
	"path/filepath"
	"sync"

	"github.com/bobo/KOTV/internal/paths"
)

// Local：Prefers key = cache_{rule}_{key}（rule 空则 cache_{key}），全局共享、无 siteKey。
var jsLocalMu sync.Mutex

// jsLocalPrefersKey Local.getKey。
func jsLocalPrefersKey(rule, key string) string {
	if rule == "" {
		return "cache_" + key
	}
	return "cache_" + rule + "_" + key
}

func jsLocalPath(rule, key string) string {
	// Prefers 键名按原文语义；落盘用 base64url，避免非法文件名且不碰撞。
	enc := base64.RawURLEncoding.EncodeToString([]byte(jsLocalPrefersKey(rule, key)))
	return filepath.Join(paths.JsCache(), "local", enc+".dat")
}

func jsLocalGet(rule, key string) string {
	jsLocalMu.Lock()
	defer jsLocalMu.Unlock()
	b, err := os.ReadFile(jsLocalPath(rule, key))
	if err != nil {
		return ""
	}
	return string(b)
}

func jsLocalSet(rule, key, value string) {
	jsLocalMu.Lock()
	defer jsLocalMu.Unlock()
	path := jsLocalPath(rule, key)
	_ = os.MkdirAll(filepath.Dir(path), 0o755)
	_ = os.WriteFile(path, []byte(value), 0o644)
}

func jsLocalDelete(rule, key string) {
	jsLocalMu.Lock()
	defer jsLocalMu.Unlock()
	_ = os.Remove(jsLocalPath(rule, key))
}
