package server

import (
	"encoding/json"
	"fmt"
	"io"
	"mime/multipart"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/bobo/KOTV/internal/paths"
)

type fileEntry struct {
	Name string `json:"name"`
	Path string `json:"path"`
	Time int64  `json:"time"`
	Dir  bool   `json:"dir"`
}

type folderResp struct {
	Parent string      `json:"parent"`
	Files  []fileEntry `json:"files"`
}

func (s *Server) handleFile(w http.ResponseWriter, r *http.Request) {
	raw := strings.TrimPrefix(r.URL.Path, "/file/")
	decoded, err := url.PathUnescape(raw)
	if err != nil {
		http.Error(w, "invalid file path", http.StatusBadRequest)
		return
	}
	name := paths.ResolveMediaPath(decoded)
	if name == "" {
		if strings.TrimSpace(decoded) == "" {
			name = paths.Data()
		} else {
			http.Error(w, "forbidden", http.StatusForbidden)
			return
		}
	}
	st, err := os.Stat(name)
	if err != nil {
		http.Error(w, "not found", http.StatusNotFound)
		return
	}
	if st.IsDir() {
		s.writeFolderJSON(w, name)
		return
	}
	http.ServeFile(w, r, name)
}

func (s *Server) writeFolderJSON(w http.ResponseWriter, dir string) {
	ents, err := os.ReadDir(dir)
	if err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	files := make([]fileEntry, 0, len(ents))
	for _, e := range ents {
		info, err := e.Info()
		if err != nil {
			continue
		}
		full := filepath.Join(dir, e.Name())
		pathOut := full
		if rel, err := filepath.Rel(paths.Data(), full); err == nil && !strings.HasPrefix(rel, "..") {
			pathOut = filepath.ToSlash(rel)
		}
		files = append(files, fileEntry{
			Name: e.Name(),
			Path: pathOut,
			Time: info.ModTime().UnixMilli(),
			Dir:  e.IsDir(),
		})
	}
	sort.Slice(files, func(i, j int) bool {
		if files[i].Dir != files[j].Dir {
			return files[i].Dir
		}
		return strings.ToLower(files[i].Name) < strings.ToLower(files[j].Name)
	})
	parent := ""
	if p := filepath.Dir(dir); p != dir && paths.UnderMediaRoot(p) {
		if rel, err := filepath.Rel(paths.Data(), p); err == nil && !strings.HasPrefix(rel, "..") {
			parent = filepath.ToSlash(rel)
		} else {
			parent = p
		}
	}
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	_ = json.NewEncoder(w).Encode(folderResp{Parent: parent, Files: files})
}

func (s *Server) handleUpload(w http.ResponseWriter, r *http.Request) {
	if r.Method != http.MethodPost {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}
	if err := r.ParseMultipartForm(256 << 20); err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}
	dir := paths.ResolveMediaPath(first(r.FormValue("path"), ""))
	if dir == "" {
		dir = paths.Data()
	}
	st, err := os.Stat(dir)
	if err != nil || !st.IsDir() {
		http.Error(w, "invalid path", http.StatusBadRequest)
		return
	}
	saved := 0
	if file, hdr, err := r.FormFile("file"); err == nil {
		defer file.Close()
		dst := filepath.Join(dir, filepath.Base(hdr.Filename))
		if err := saveUpload(file, dst); err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		saved++
	}
	// 兼容遥控端：files-0 / files-1 …
	if r.MultipartForm != nil {
		for name, fhs := range r.MultipartForm.File {
			if name == "file" || !strings.HasPrefix(name, "files") {
				continue
			}
			for _, hdr := range fhs {
				src, err := hdr.Open()
				if err != nil {
					continue
				}
				dst := filepath.Join(dir, filepath.Base(hdr.Filename))
				err = saveUpload(src, dst)
				_ = src.Close()
				if err != nil {
					http.Error(w, err.Error(), http.StatusInternalServerError)
					return
				}
				saved++
			}
		}
	}
	if saved == 0 {
		http.Error(w, "missing file", http.StatusBadRequest)
		return
	}
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write([]byte("OK"))
}

func saveUpload(src multipart.File, dst string) error {
	f, err := os.Create(dst)
	if err != nil {
		return err
	}
	defer f.Close()
	_, err = io.Copy(f, src)
	return err
}

func (s *Server) handleNewFolder(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	_ = r.ParseForm()
	base := first(q.Get("path"), r.Form.Get("path"))
	name := first(q.Get("name"), r.Form.Get("name"))
	dir := paths.ResolveMediaPath(base)
	if dir == "" {
		dir = paths.Data()
	}
	name = filepath.Base(strings.TrimSpace(name))
	if name == "" || name == "." || name == ".." {
		http.Error(w, "invalid name", http.StatusBadRequest)
		return
	}
	if err := os.MkdirAll(filepath.Join(dir, name), 0o755); err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	w.WriteHeader(http.StatusOK)
	_, _ = fmt.Fprint(w, "OK")
}

func (s *Server) handleDelPath(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	_ = r.ParseForm()
	raw := first(q.Get("path"), r.Form.Get("path"))
	name := paths.ResolveMediaPath(raw)
	if name == "" || name == paths.Data() || name == paths.Downloads() {
		http.Error(w, "forbidden", http.StatusForbidden)
		return
	}
	if err := os.RemoveAll(name); err != nil {
		http.Error(w, err.Error(), http.StatusInternalServerError)
		return
	}
	w.WriteHeader(http.StatusOK)
	_, _ = fmt.Fprint(w, "OK")
}

func (s *Server) handleCache(w http.ResponseWriter, r *http.Request) {
	q := r.URL.Query()
	_ = r.ParseForm()
	do := first(q.Get("do"), r.Form.Get("do"))
	key := first(q.Get("key"), r.Form.Get("key"))
	if key == "" {
		http.Error(w, "missing key", http.StatusBadRequest)
		return
	}
	dir := paths.HttpCache()
	file := filepath.Join(dir, sanitizeCacheKey(key))
	switch do {
	case "get":
		b, err := os.ReadFile(file)
		if err != nil {
			http.Error(w, "not found", http.StatusNotFound)
			return
		}
		w.Header().Set("Content-Type", "application/octet-stream")
		_, _ = w.Write(b)
	case "set":
		val := first(q.Get("value"), r.Form.Get("value"))
		if val == "" && r.Body != nil {
			b, _ := io.ReadAll(io.LimitReader(r.Body, 4<<20))
			val = string(b)
		}
		if err := os.WriteFile(file, []byte(val), 0o644); err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		_, _ = fmt.Fprint(w, "OK")
	case "del":
		_ = os.Remove(file)
		_, _ = fmt.Fprint(w, "OK")
	default:
		http.Error(w, "unknown do", http.StatusBadRequest)
	}
}

func sanitizeCacheKey(key string) string {
	key = strings.Map(func(r rune) rune {
		switch {
		case r >= 'a' && r <= 'z', r >= 'A' && r <= 'Z', r >= '0' && r <= '9', r == '-', r == '_', r == '.':
			return r
		default:
			return '_'
		}
	}, key)
	if len(key) > 120 {
		key = key[:120]
	}
	if key == "" {
		key = fmt.Sprintf("k_%d", time.Now().UnixNano())
	}
	return key
}
