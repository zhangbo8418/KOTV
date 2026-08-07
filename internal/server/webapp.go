package server

import (
	"io/fs"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"strings"
)

// resolveWebappDir 查找 Flutter Web 静态根（含 index.html）。
// 仅 Web 发行包会带 webapp/；PC/安卓/iOS 包不含，此时 / 仍为遥控页。
func resolveWebappDir() string {
	if v := strings.TrimSpace(os.Getenv("KOTV_WEBAPP")); v != "" {
		if webappHasIndex(v) {
			return filepath.Clean(v)
		}
	}
	var candidates []string
	if exe, err := os.Executable(); err == nil {
		dir := filepath.Dir(exe)
		candidates = append(candidates,
			filepath.Join(dir, "webapp"),
			filepath.Join(dir, "..", "webapp"), // 部分打包布局
		)
	}
	if cwd, err := os.Getwd(); err == nil {
		candidates = append(candidates, filepath.Join(cwd, "webapp"))
	}
	for _, c := range candidates {
		if webappHasIndex(c) {
			return filepath.Clean(c)
		}
	}
	return ""
}

func webappHasIndex(dir string) bool {
	st, err := os.Stat(filepath.Join(dir, "index.html"))
	return err == nil && !st.IsDir()
}

// mountWebOrRemote：有 webapp 时引擎同端口放出 Web（/），遥控挪到 /remote/；
// 否则 / 仍为遥控页。不把 Web 打进普通客户端包。
func mountWebOrRemote(mux *http.ServeMux, remote fs.FS) {
	remoteServer := http.FileServer(http.FS(remote))
	webRoot := resolveWebappDir()

	if webRoot == "" {
		mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
			serveLocalAssetOr(w, r, remoteServer)
		})
		return
	}

	log.Printf("HTTP Web UI: / ← %s ；遥控 /remote/ ；管理 /admin/", webRoot)
	mux.Handle("/remote/", http.StripPrefix("/remote/", remoteServer))
	mux.HandleFunc("/remote", func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, "/remote/", http.StatusFound)
	})
	// 管理页与遥控共享的 css/js（admin 用绝对路径 /css/…）
	mux.Handle("/admin/", remoteServer)
	mux.Handle("/css/", remoteServer)
	mux.Handle("/js/", remoteServer)

	webFS := http.FileServer(http.Dir(webRoot))
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodGet && r.Method != http.MethodHead {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}
		rel := strings.TrimPrefix(filepath.Clean("/"+r.URL.Path), "/")
		if rel == "." || rel == "" {
			rel = "index.html"
		}
		candidate := filepath.Join(webRoot, filepath.FromSlash(rel))
		if st, err := os.Stat(candidate); err == nil && !st.IsDir() {
			webFS.ServeHTTP(w, r)
			return
		}
		// 本地 assets 兜底（与旧遥控行为一致）
		if rel != "index.html" {
			if p, ok := safeAssetPath(rel); ok {
				if st, err := os.Stat(p); err == nil && !st.IsDir() {
					http.ServeFile(w, r, p)
					return
				}
			}
		}
		// SPA：无实体文件时回落 index.html（不含带扩展名的资源 404）
		if strings.Contains(filepath.Base(rel), ".") && rel != "index.html" {
			http.NotFound(w, r)
			return
		}
		http.ServeFile(w, r, filepath.Join(webRoot, "index.html"))
	})
}

func serveLocalAssetOr(w http.ResponseWriter, r *http.Request, fallback http.Handler) {
	if rel := strings.TrimPrefix(r.URL.Path, "/"); rel != "" && rel != "index.html" {
		if candidate, ok := safeAssetPath(rel); ok {
			if st, err := os.Stat(candidate); err == nil && !st.IsDir() {
				http.ServeFile(w, r, candidate)
				return
			}
		}
	}
	fallback.ServeHTTP(w, r)
}
