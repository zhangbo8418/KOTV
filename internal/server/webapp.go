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

// webRoutes 静态页面：有 webapp 时同端口 / 放出 Web，遥控挪到 /remote/；
// 否则 / 仍为遥控页。不把 Web 打进普通客户端包。
func webRoutes(remote fs.FS) []route {
	remoteServer := http.FileServer(http.FS(remote))
	webRoot := resolveWebappDir()
	if webRoot == "" {
		// 无 Flutter webapp 时 / 仍为遥控；同时挂 /css/、/js/、/img/，供遥控/管理页用绝对路径。
		return []route{
			{"/css/", needPublic, remoteServer.ServeHTTP},
			{"/js/", needPublic, remoteServer.ServeHTTP},
			{"/img/", needPublic, remoteServer.ServeHTTP},
			{"/admin/", needPublic, remoteServer.ServeHTTP},
			{"/", needPublic, func(w http.ResponseWriter, r *http.Request) {
				serveLocalAssetOr(w, r, remoteServer)
			}},
		}
	}

	log.Printf("HTTP Web UI: / ← %s ；遥控 /remote/ ；管理 /admin/", webRoot)
	webFS := http.FileServer(http.Dir(webRoot))
	return []route{
		{"/remote/", needPublic, http.StripPrefix("/remote/", remoteServer).ServeHTTP},
		{"/remote", needPublic, func(w http.ResponseWriter, r *http.Request) {
			http.Redirect(w, r, "/remote/", http.StatusFound)
		}},
		// 管理页与遥控共享的 css/js/img（admin 用绝对路径 /css/…）
		{"/admin/", needPublic, remoteServer.ServeHTTP},
		{"/css/", needPublic, remoteServer.ServeHTTP},
		{"/js/", needPublic, remoteServer.ServeHTTP},
		{"/img/", needPublic, remoteServer.ServeHTTP},
		{"/", needPublic, func(w http.ResponseWriter, r *http.Request) {
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
			if rel != "index.html" && serveHostAsset(w, r, rel) {
				return
			}
			// SPA：无实体文件时回落 index.html（不含带扩展名的资源 404）
			if strings.Contains(filepath.Base(rel), ".") && rel != "index.html" {
				http.NotFound(w, r)
				return
			}
			http.ServeFile(w, r, filepath.Join(webRoot, "index.html"))
		}},
	}
}

func serveLocalAssetOr(w http.ResponseWriter, r *http.Request, fallback http.Handler) {
	if rel := strings.TrimPrefix(r.URL.Path, "/"); rel != "" && rel != "index.html" && serveHostAsset(w, r, rel) {
		return
	}
	fallback.ServeHTTP(w, r)
}

// serveHostAsset 主机 assets 目录里的文件。这是主机上的文件，远端要登录才能读。
func serveHostAsset(w http.ResponseWriter, r *http.Request, rel string) bool {
	if requestAccess(r) != accessFull {
		return false
	}
	p, ok := safeAssetPath(rel)
	if !ok {
		return false
	}
	if st, err := os.Stat(p); err != nil || st.IsDir() {
		return false
	}
	http.ServeFile(w, r, p)
	return true
}
