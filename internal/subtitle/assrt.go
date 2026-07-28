package subtitle

import (
	"archive/zip"
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"

	"github.com/bobo/KOTV/internal/paths"
	"github.com/bobo/KOTV/internal/settings"
	"github.com/bobo/KOTV/internal/util"
)

const assrtBase = "https://api.assrt.net"

// Item 搜索结果条目。
type Item struct {
	ID         int64
	NativeName string
	VideoName  string
	Subtype    string
	LangDesc   string
	Site       string
}

// FileEntry 字幕包内的单文件（或直链字幕）。
type FileEntry struct {
	Name string
	URL  string
	Size string
}

type searchResp struct {
	Status int `json:"status"`
	Sub    struct {
		Result string `json:"result"`
		Subs   []struct {
			ID         int64  `json:"id"`
			NativeName string `json:"native_name"`
			VideoName  string `json:"videoname"`
			Subtype    string `json:"subtype"`
			Release    string `json:"release_site"`
			Lang       struct {
				Desc string `json:"desc"`
			} `json:"lang"`
		} `json:"subs"`
	} `json:"sub"`
}

type detailResp struct {
	Status int `json:"status"`
	Sub    struct {
		Result string `json:"result"`
		Subs   []struct {
			ID       int64  `json:"id"`
			URL      string `json:"url"`
			Filename string `json:"filename"`
			Subtype  string `json:"subtype"`
			Filelist []struct {
				URL  string `json:"url"`
				Name string `json:"f"`
				Size string `json:"s"`
			} `json:"filelist"`
		} `json:"subs"`
	} `json:"sub"`
}

// Token 返回设置中的 Assrt Token。
func Token() string {
	return strings.TrimSpace(settings.Get(settings.AssrtToken))
}

// HasToken 是否已配置 Token。
func HasToken() bool { return Token() != "" }

func SubCache() string { return paths.Ensure(filepath.Join(paths.Data(), "cache", "sub")) }

// Search 用片名搜索字幕（Assrt）。
func Search(query string, limit int) ([]Item, error) {
	query = strings.TrimSpace(query)
	if len([]rune(query)) < 2 {
		return nil, fmt.Errorf("搜索关键词太短")
	}
	token := Token()
	if token == "" {
		return nil, fmt.Errorf("未配置 Assrt Token：请到设置填写")
	}
	if limit <= 0 || limit > 15 {
		limit = 15
	}
	raw, err := util.HTTPGetParams(assrtBase+"/v1/sub/search", nil, map[string]string{
		"token":     token,
		"q":         query,
		"cnt":       strconv.Itoa(limit),
		"no_muxer":  "1",
		"filelist":  "0",
	})
	if err != nil {
		return nil, err
	}
	var resp searchResp
	if err := json.Unmarshal([]byte(raw), &resp); err != nil {
		return nil, err
	}
	if resp.Status != 0 {
		return nil, fmt.Errorf("Assrt 搜索失败(status=%d)", resp.Status)
	}
	out := make([]Item, 0, len(resp.Sub.Subs))
	for _, s := range resp.Sub.Subs {
		out = append(out, Item{
			ID:         s.ID,
			NativeName: s.NativeName,
			VideoName:  s.VideoName,
			Subtype:    s.Subtype,
			LangDesc:   s.Lang.Desc,
			Site:       s.Release,
		})
	}
	return out, nil
}

// DetailFiles 获取字幕下载文件列表（优先 filelist 中的 srt/ass）。
func DetailFiles(id int64) ([]FileEntry, error) {
	token := Token()
	if token == "" {
		return nil, fmt.Errorf("未配置 Assrt Token")
	}
	raw, err := util.HTTPGetParams(assrtBase+"/v1/sub/detail", nil, map[string]string{
		"token": token,
		"id":    strconv.FormatInt(id, 10),
	})
	if err != nil {
		return nil, err
	}
	var resp detailResp
	if err := json.Unmarshal([]byte(raw), &resp); err != nil {
		return nil, err
	}
	if resp.Status != 0 || len(resp.Sub.Subs) == 0 {
		return nil, fmt.Errorf("Assrt 详情失败(status=%d)", resp.Status)
	}
	sub := resp.Sub.Subs[0]
	var files []FileEntry
	for _, f := range sub.Filelist {
		if !isSubtitleName(f.Name) {
			continue
		}
		files = append(files, FileEntry{Name: f.Name, URL: f.URL, Size: f.Size})
	}
	if len(files) > 0 {
		return files, nil
	}
	// 无 filelist：若 url 本身是字幕则直接用；若是 zip 则下载解压。
	if isSubtitleName(sub.Filename) || isSubtitleURL(sub.URL) {
		name := sub.Filename
		if name == "" {
			name = filepath.Base(stripQuery(sub.URL))
		}
		return []FileEntry{{Name: name, URL: sub.URL}}, nil
	}
	if strings.HasSuffix(strings.ToLower(sub.Filename), ".zip") || strings.Contains(strings.ToLower(sub.URL), ".zip") {
		return []FileEntry{{Name: sub.Filename, URL: sub.URL, Size: "zip"}}, nil
	}
	return nil, fmt.Errorf("该条目无可直接加载的字幕文件（可能是 rar 压缩包）")
}

// DownloadToCache 下载字幕到本地缓存并返回路径。
// 若 URL 指向 zip，则解压出第一个字幕文件。
func DownloadToCache(entry FileEntry) (string, error) {
	if entry.URL == "" {
		return "", fmt.Errorf("空下载地址")
	}
	data, err := util.HTTPGetBytes(entry.URL, map[string]string{
		"User-Agent": "KOTV/1.0",
		"Referer":    "https://assrt.net/",
	})
	if err != nil {
		return "", err
	}
	dir := SubCache()
	name := entry.Name
	if name == "" {
		name = filepath.Base(stripQuery(entry.URL))
	}
	name = sanitizeName(name)

	if entry.Size == "zip" || strings.HasSuffix(strings.ToLower(name), ".zip") || looksLikeZip(data) {
		path, err := extractFirstSubFromZip(data, dir)
		if err != nil {
			return "", err
		}
		return path, nil
	}
	if !isSubtitleName(name) {
		name += ".srt"
	}
	dest := filepath.Join(dir, fmt.Sprintf("%s_%s", util.MD5(entry.URL)[:10], name))
	if err := os.WriteFile(dest, data, 0o644); err != nil {
		return "", err
	}
	return dest, nil
}

// DisplayTitle 列表展示文案。
func (it Item) DisplayTitle() string {
	name := it.NativeName
	if name == "" {
		name = it.VideoName
	}
	if name == "" {
		name = fmt.Sprintf("字幕 #%d", it.ID)
	}
	var tags []string
	if it.LangDesc != "" {
		tags = append(tags, it.LangDesc)
	}
	if it.Subtype != "" {
		tags = append(tags, it.Subtype)
	}
	if it.Site != "" {
		tags = append(tags, it.Site)
	}
	if len(tags) == 0 {
		return name
	}
	return name + " · " + strings.Join(tags, " · ")
}

func isSubtitleName(name string) bool {
	ext := strings.ToLower(filepath.Ext(name))
	switch ext {
	case ".srt", ".ass", ".ssa", ".vtt", ".sub":
		return true
	}
	return false
}

func isSubtitleURL(raw string) bool {
	return isSubtitleName(stripQuery(raw))
}

func stripQuery(raw string) string {
	if u, err := url.Parse(raw); err == nil {
		return u.Path
	}
	if i := strings.Index(raw, "?"); i >= 0 {
		return raw[:i]
	}
	return raw
}

func sanitizeName(name string) string {
	name = filepath.Base(name)
	name = strings.Map(func(r rune) rune {
		switch r {
		case '/', '\\', ':', '*', '?', '"', '<', '>', '|':
			return '_'
		}
		return r
	}, name)
	if name == "" || name == "." {
		return "subtitle.srt"
	}
	return name
}

func looksLikeZip(b []byte) bool {
	return len(b) >= 4 && b[0] == 'P' && b[1] == 'K'
}

func extractFirstSubFromZip(data []byte, dir string) (string, error) {
	r, err := zip.NewReader(bytes.NewReader(data), int64(len(data)))
	if err != nil {
		return "", fmt.Errorf("无法解压 zip: %w", err)
	}
	for _, f := range r.File {
		if f.FileInfo().IsDir() || !isSubtitleName(f.Name) {
			continue
		}
		rc, err := f.Open()
		if err != nil {
			continue
		}
		body, err := io.ReadAll(io.LimitReader(rc, 8<<20))
		_ = rc.Close()
		if err != nil {
			continue
		}
		dest := filepath.Join(dir, fmt.Sprintf("%s_%s", util.MD5(f.Name)[:10], sanitizeName(f.Name)))
		if err := os.WriteFile(dest, body, 0o644); err != nil {
			return "", err
		}
		return dest, nil
	}
	return "", fmt.Errorf("zip 内未找到字幕文件")
}
