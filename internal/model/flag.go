package model

import (
	"fmt"
	"strings"
)

// Flag 播放线路。
type Flag struct {
	Flag      string    `json:"flag"`
	Show      string    `json:"show"`
	URLs      string    `json:"urls"`
	Episodes  []Episode `json:"-"`
	Activated bool      `json:"-"`
	Position  int       `json:"-"`
}

func CreateFlag(name string) Flag {
	return Flag{
		Flag:     name,
		Show:     name,
		Position: -1,
	}
}

// CreateEpisode 解析 name$url#name1$url1 格式。
// 兼容全角 ＄，以及误用空格分隔的「第N集 /path」或「第N集 https://…」。
func (f *Flag) CreateEpisode(url string) {
	if strings.TrimSpace(url) == "" {
		return
	}
	parts := strings.Split(url, "#")
	if len(parts) == 1 {
		parts = []string{url}
	}
	for i, part := range parts {
		number := fmt.Sprintf("%02d", i+1)
		part = strings.ReplaceAll(part, "＄", "$")
		split := strings.SplitN(part, "$", 2)
		var ep Episode
		if len(split) > 1 {
			name := strings.TrimSpace(split[0])
			if name == "" {
				name = number
			}
			ep = CreateEpisode(name, CleanEpisodePlayURL(split[1]))
		} else if name, u, ok := splitLooseEpisode(part); ok {
			ep = CreateEpisode(name, u)
		} else {
			ep = CreateEpisode(number, CleanEpisodePlayURL(part))
		}
		if !containsEpisode(f.Episodes, ep) {
			f.Episodes = append(f.Episodes, ep)
		}
	}
}

// CleanEpisodePlayURL 去掉误拼进地址的集名（如「第01集 /index.php/…」或「第01集$第01集 /path」的后半段）。
func CleanEpisodePlayURL(u string) string {
	u = strings.TrimSpace(strings.ReplaceAll(u, "＄", "$"))
	if u == "" {
		return u
	}
	if _, rest, ok := splitLooseEpisode(u); ok {
		return rest
	}
	return u
}

// splitLooseEpisode 识别「名称 + 空白 + 地址」且无 $ 分隔的脏数据。
func splitLooseEpisode(part string) (name, u string, ok bool) {
	part = strings.TrimSpace(part)
	for i := 0; i < len(part); i++ {
		if part[i] != ' ' && part[i] != '\t' {
			continue
		}
		rest := strings.TrimSpace(part[i+1:])
		if rest == "" {
			continue
		}
		if strings.HasPrefix(rest, "http://") || strings.HasPrefix(rest, "https://") ||
			strings.HasPrefix(rest, "/") || strings.HasPrefix(rest, "magnet:") ||
			strings.HasPrefix(rest, "ed2k:") {
			name = strings.TrimSpace(part[:i])
			if name == "" {
				return "", "", false
			}
			return name, rest, true
		}
	}
	return "", "", false
}

func containsEpisode(eps []Episode, ep Episode) bool {
	for _, e := range eps {
		if e.Name == ep.Name && e.URL == ep.URL {
			return true
		}
	}
	return false
}

func (f *Flag) Find(remarks string, strict bool) *Episode {
	number := GetDigit(remarks)
	if len(f.Episodes) == 0 {
		return nil
	}
	if len(f.Episodes) == 1 {
		return &f.Episodes[0]
	}
	for i := range f.Episodes {
		if f.Episodes[i].Rule1(remarks) {
			return &f.Episodes[i]
		}
	}
	for i := range f.Episodes {
		if f.Episodes[i].Rule2(number) {
			return &f.Episodes[i]
		}
	}
	if number == -1 {
		for i := range f.Episodes {
			if f.Episodes[i].Rule3(remarks) {
				return &f.Episodes[i]
			}
		}
	}
	if f.Position >= 0 && f.Position < len(f.Episodes) {
		return &f.Episodes[f.Position]
	}
	if strict {
		return nil
	}
	return &f.Episodes[0]
}
