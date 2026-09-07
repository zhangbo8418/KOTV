package service

import (
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"

	"github.com/bobo/KOTV/internal/model"
	"github.com/bobo/KOTV/internal/paths"
)

// localDirCategory 列目录 + 媒体文件。
// tid 为绝对路径（或 file://）且目录可读时返回 true；不依赖 jar 内 Util.isMedia。
func localDirCategory(tid string) (model.Result, bool) {
	dir := resolveLocalBrowseDir(tid)
	if dir == "" {
		return model.Result{}, false
	}
	st, err := os.Stat(dir)
	if err != nil || !st.IsDir() {
		return model.Result{}, false
	}
	ents, err := os.ReadDir(dir)
	if err != nil {
		return model.Result{}, false
	}
	type row struct {
		name string
		path string
		dir  bool
		mod  time.Time
	}
	rows := make([]row, 0, len(ents))
	for _, e := range ents {
		name := e.Name()
		if name == "" || strings.HasPrefix(name, ".") {
			continue
		}
		info, err := e.Info()
		if err != nil {
			continue
		}
		if e.IsDir() {
			rows = append(rows, row{
				name: name,
				path: filepath.Join(dir, name),
				dir:  true,
				mod:  info.ModTime(),
			})
			continue
		}
		if !paths.IsMediaFilename(name) {
			continue
		}
		rows = append(rows, row{
			name: name,
			path: filepath.Join(dir, name),
			dir:  false,
			mod:  info.ModTime(),
		})
	}
	sort.Slice(rows, func(i, j int) bool {
		if rows[i].dir != rows[j].dir {
			return rows[i].dir
		}
		return strings.ToLower(rows[i].name) < strings.ToLower(rows[j].name)
	})
	list := make([]model.Vod, 0, len(rows))
	for _, r := range rows {
		tag := "file"
		if r.dir {
			tag = "folder"
		}
		list = append(list, model.Vod{
			VodID:      model.FlexString(r.path),
			VodName:    r.name,
			VodRemarks: r.mod.Format("2006/01/02 15:04:05"),
			VodTag:     tag,
		})
	}
	return model.Result{Success: true, List: list, PageCount: model.FlexInt{Valid: true, Value: 1}}, true
}

func resolveLocalBrowseDir(tid string) string {
	raw := strings.TrimSpace(tid)
	if raw == "" {
		return ""
	}
	if resolved := paths.ResolveMediaPath(raw); resolved != "" {
		return resolved
	}
	raw = strings.TrimPrefix(raw, "file://")
	raw = strings.TrimPrefix(raw, "file:")
	raw = filepath.Clean(raw)
	if !filepath.IsAbs(raw) {
		return ""
	}
	return raw
}
