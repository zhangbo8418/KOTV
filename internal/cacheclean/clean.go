// Package cacheclean 清理爬虫/磁力/日志等用户缓存（不删设置与数据库）。
package cacheclean

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/bobo/KOTV/internal/paths"
	"github.com/bobo/KOTV/internal/spider"
	"github.com/bobo/KOTV/internal/thunder"
)

// Options 选择清理项。
type Options struct {
	Script bool // JS / Python 落盘
	Jar    bool // JAR 包与 bridge 侧 cache/jar
	Magnet bool // 磁力种子与下载缓冲
	Logs   bool // 引擎/桥接日志
	Other  bool // http/epg/sub/pic 等杂项缓存
}

// Result 清理结果摘要。
type Result struct {
	FreedBytes int64             `json:"freedBytes"`
	FreedHuman string            `json:"freedHuman"`
	Cleared    []string          `json:"cleared"`
	Errors     []string          `json:"errors,omitempty"`
	Details    map[string]string `json:"details,omitempty"`
}

// All 默认全选。
func All() Options {
	return Options{Script: true, Jar: true, Magnet: true, Logs: true, Other: true}
}

// Run 执行清理。运行中可调用；磁力会关闭 BT 客户端。
func Run(opt Options) Result {
	res := Result{Details: map[string]string{}, Cleared: []string{}}
	add := func(label, path string, n int64, err error) {
		if err != nil {
			res.Errors = append(res.Errors, fmt.Sprintf("%s: %v", label, err))
			return
		}
		res.FreedBytes += n
		res.Cleared = append(res.Cleared, label)
		res.Details[label] = fmt.Sprintf("%s (%s)", path, humanBytes(n))
	}

	if opt.Script {
		spider.InterruptScriptSpiders()
		spider.ResetScriptSpiders()
		n, err := wipeDirKeepRoot(paths.JsCache())
		add("JS", paths.JsCache(), n, err)
		n, err = wipeDirKeepRoot(paths.PyCache())
		add("Python", paths.PyCache(), n, err)
		// CatVod Path.py / Path.js
		n, err = wipeDirKeepRoot(filepath.Join(paths.Root(), "cache", "js"))
		if n > 0 || err == nil {
			add("JS(bridge)", filepath.Join(paths.Root(), "cache", "js"), n, err)
		}
		n, err = wipeDirKeepRoot(filepath.Join(paths.Root(), "cache", "py"))
		if n > 0 || err == nil {
			add("Python(bridge)", filepath.Join(paths.Root(), "cache", "py"), n, err)
		}
	}

	if opt.Jar {
		spider.ClearJarDisk()
		n, err := wipeDirKeepRoot(paths.JarCache())
		add("JAR", paths.JarCache(), n, err)
		n, err = wipeDirKeepRoot(filepath.Join(paths.Root(), "cache", "jar"))
		add("JAR(bridge)", filepath.Join(paths.Root(), "cache", "jar"), n, err)
		n, err = wipeDirKeepRoot(filepath.Join(paths.Root(), "cache", "jpa"))
		if n > 0 {
			add("JPA", filepath.Join(paths.Root(), "cache", "jpa"), n, err)
		}
		n, err = wipeDirKeepRoot(filepath.Join(paths.Root(), "cache", "proxy"))
		if n > 0 {
			add("代理溢写", filepath.Join(paths.Root(), "cache", "proxy"), n, err)
		}
	}

	if opt.Magnet {
		n, err := thunder.ClearStorage()
		add("磁力下载", filepath.Join(paths.Root(), "thunder"), n, err)
		n2, err2 := wipeDirRemove(filepath.Join(paths.Root(), "bt"))
		if n2 > 0 || (err2 == nil && dirExists(filepath.Join(paths.Root(), "bt"))) {
			add("BT遗留", filepath.Join(paths.Root(), "bt"), n2, err2)
		}
		n3, err3 := wipeDirKeepRoot(filepath.Join(paths.Root(), "cache", "thunder"))
		if n3 > 0 {
			add("磁力(bridge)", filepath.Join(paths.Root(), "cache", "thunder"), n3, err3)
		}
	}

	if opt.Logs {
		n, err := clearLogs(paths.LogDir())
		add("日志", paths.LogDir(), n, err)
	}

	if opt.Other {
		for _, item := range []struct{ label, path string }{
			{"HTTP缓存", filepath.Join(paths.Data(), "cache", "http")},
			{"EPG", paths.EpgCache()},
			{"字幕", filepath.Join(paths.Data(), "cache", "sub")},
			{"封面", paths.PicCache()},
			{"更新包", filepath.Join(paths.Root(), "update")},
		} {
			n, err := wipeDirKeepRoot(item.path)
			if n > 0 || err != nil {
				add(item.label, item.path, n, err)
			}
		}
	}

	res.FreedHuman = humanBytes(res.FreedBytes)
	return res
}

func clearLogs(dir string) (int64, error) {
	_ = os.MkdirAll(dir, 0o755)
	entries, err := os.ReadDir(dir)
	if err != nil {
		return 0, err
	}
	var freed int64
	for _, e := range entries {
		p := filepath.Join(dir, e.Name())
		info, err := e.Info()
		if err != nil {
			continue
		}
		sz := info.Size()
		// kotv.log 可能仍被进程占用：截断而不是删除。
		if strings.EqualFold(e.Name(), "kotv.log") || strings.HasSuffix(strings.ToLower(e.Name()), ".log") {
			if err := truncateFile(p); err != nil {
				_ = os.Remove(p)
			}
			freed += sz
			continue
		}
		if e.IsDir() {
			n, _ := wipeDirRemove(p)
			freed += n
			continue
		}
		if err := os.Remove(p); err == nil {
			freed += sz
		}
	}
	return freed, nil
}

func truncateFile(p string) error {
	f, err := os.OpenFile(p, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0o644)
	if err != nil {
		return err
	}
	return f.Close()
}

func wipeDirKeepRoot(dir string) (int64, error) {
	n, err := dirSize(dir)
	if err != nil && !os.IsNotExist(err) {
		return 0, err
	}
	_ = os.RemoveAll(dir)
	_ = os.MkdirAll(dir, 0o755)
	return n, nil
}

func wipeDirRemove(dir string) (int64, error) {
	n, err := dirSize(dir)
	if err != nil && !os.IsNotExist(err) {
		return 0, err
	}
	if err := os.RemoveAll(dir); err != nil && !os.IsNotExist(err) {
		return n, err
	}
	return n, nil
}

func dirSize(root string) (int64, error) {
	var total int64
	err := filepath.Walk(root, func(_ string, info os.FileInfo, err error) error {
		if err != nil {
			return nil
		}
		if !info.IsDir() {
			total += info.Size()
		}
		return nil
	})
	return total, err
}

func dirExists(p string) bool {
	st, err := os.Stat(p)
	return err == nil && st.IsDir()
}

func humanBytes(n int64) string {
	if n <= 0 {
		return "0 B"
	}
	units := []string{"B", "KB", "MB", "GB", "TB"}
	v := float64(n)
	i := 0
	for v >= 1024 && i < len(units)-1 {
		v /= 1024
		i++
	}
	if i == 0 {
		return fmt.Sprintf("%d %s", n, units[i])
	}
	return fmt.Sprintf("%.1f %s", v, units[i])
}
