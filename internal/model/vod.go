package model

import (
	"regexp"
	"strconv"
	"strings"
)

// Vod 影视条目。
type Vod struct {
	VodID       FlexString `json:"vod_id"`
	VodName     string     `json:"vod_name"`
	TypeName    string     `json:"type_name"`
	VodPic      string     `json:"vod_pic"`
	VodRemarks  string     `json:"vod_remarks"`
	VodYear     FlexString `json:"vod_year"`
	VodArea     string     `json:"vod_area"`
	VodDirector string     `json:"vod_director"`
	VodActor    string     `json:"vod_actor"`
	VodContent  string     `json:"vod_content"`
	VodPlayFrom string     `json:"vod_play_from"`
	VodPlayURL  string     `json:"vod_play_url"`
	VodTag      string     `json:"vod_tag"`
	Action      string     `json:"action"`
	Cate        FlexString `json:"cate"`
	Style       *Style     `json:"style"`
	Land        FlexString `json:"land"`
	Circle      FlexString `json:"circle"`
	Ratio       FlexString `json:"ratio"`
	VodFlags    []Flag     `json:"-"`
	Site        *Site      `json:"-"`
	CurrentFlag Flag       `json:"-"`
	SubEpisode  []Episode  `json:"-"`
	CurrentTab  int        `json:"-"`
}

const EpSize = 20

var flagSplit = regexp.MustCompile(`\$\$\$`)

func (v *Vod) IsEmpty() bool {
	return strings.TrimSpace(v.VodID.String()) == "" || len(v.VodFlags) == 0
}

func (v *Vod) IsFolder() bool {
	tag := strings.ToLower(strings.TrimSpace(v.VodTag))
	if tag == "file" {
		return false
	}
	if tag == "folder" {
		return true
	}
	// `cate` 对象存在即当目录。
	return strings.TrimSpace(v.Cate.String()) != ""
}

// IsAction Vod.isAction：有 action 字段时走站点 action 而非详情。
func (v *Vod) IsAction() bool {
	return strings.TrimSpace(v.Action) != ""
}

func (v *Vod) SetVodFlags() {
	// 已有 XML dl/dd 解析出的 Flags 时只补全集数。
	if len(v.VodFlags) > 0 {
		for i := range v.VodFlags {
			if len(v.VodFlags[i].Episodes) == 0 && v.VodFlags[i].URLs != "" {
				v.VodFlags[i].CreateEpisode(v.VodFlags[i].URLs)
			}
		}
		v.SetCurrentFlag(0)
		return
	}
	if v.VodPlayFrom == "" || v.VodPlayURL == "" {
		return
	}
	playFlags := flagSplit.Split(v.VodPlayFrom, -1)
	playURLs := flagSplit.Split(v.VodPlayURL, -1)
	// 同名线路全部保留（站点会给同名不同内容的线路）；线路名或对应 url 为空的跳过。
	for i, name := range playFlags {
		name = strings.TrimSpace(name)
		if name == "" || i >= len(playURLs) || playURLs[i] == "" {
			continue
		}
		f := CreateFlag(name)
		f.URLs = playURLs[i]
		f.CreateEpisode(playURLs[i])
		v.VodFlags = append(v.VodFlags, f)
	}
	v.SetCurrentFlag(0)
}

func (v *Vod) SetCurrentFlag(idx int) {
	if len(v.VodFlags) == 0 {
		return
	}
	if idx < 0 || idx >= len(v.VodFlags) {
		idx = 0
	}
	for i := range v.VodFlags {
		v.VodFlags[i].Activated = i == idx
	}
	v.CurrentFlag = v.VodFlags[idx]
	v.CurrentFlag.Activated = true
}

func (v *Vod) ActiveEpisode() *Episode {
	for i := range v.CurrentFlag.Episodes {
		if v.CurrentFlag.Episodes[i].Activated {
			return &v.CurrentFlag.Episodes[i]
		}
	}
	return nil
}

func EpisodePage(eps []Episode, index int) []Episode {
	if len(eps) == 0 {
		return nil
	}
	from := index * EpSize
	if from >= len(eps) {
		lastPage := ((len(eps) - 1) / EpSize) * EpSize
		return eps[lastPage:]
	}
	to := from + EpSize
	if to > len(eps) {
		to = len(eps)
	}
	return eps[from:to]
}

var (
	getDigitBracket = regexp.MustCompile(`\[.*?\]|\(.*?\)`)
	getDigitYear    = regexp.MustCompile(`(^|[^0-9])((?:19|20)\d{2})([^0-9]|$)`)
	getDigitRes     = regexp.MustCompile(`(?i)2160p|1080p|720p|480p|4k|h26[45]|x26[45]|mp4`)
	getDigitEp      = regexp.MustCompile(`(?i)(?:ep|第|e|[-\.\s])\s?(\d{1,4})`)
	getDigitDigits  = regexp.MustCompile(`\D+`)
)

// GetDigit 从备注/集名中抽集数：去括号与年份与分辨率后，优先匹配「第|ep|e」数字，否则拼剩余数字。
func GetDigit(s string) int {
	text := getDigitBracket.ReplaceAllString(s, "")
	for {
		loc := getDigitYear.FindStringSubmatchIndex(text)
		if loc == nil {
			break
		}
		// 保留前后非数字边界字符，只删年份本身。
		text = text[:loc[4]] + text[loc[5]:]
	}
	text = getDigitRes.ReplaceAllString(strings.ToLower(text), "")
	if m := getDigitEp.FindStringSubmatch(text); len(m) > 1 {
		n, err := strconv.Atoi(m[1])
		if err == nil {
			return n
		}
	}
	number := getDigitDigits.ReplaceAllString(text, "")
	if number == "" {
		return -1
	}
	n, err := strconv.Atoi(number)
	if err != nil {
		return -1
	}
	return n
}
