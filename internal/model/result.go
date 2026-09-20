package model

import (
	"bytes"
	"encoding/json"
	"strings"

	"github.com/bobo/KOTV/internal/lenientjson"
)

// Result 爬虫返回结果。
type Result struct {
	Types     []Type      `json:"class"`
	List      []Vod       `json:"list"`
	Filters   FilterMap   `json:"filters"`
	Header    FlexHeader  `json:"header"`
	PlayURL   string      `json:"playUrl"`
	JxFrom    string      `json:"jxFrom"`
	Parse     FlexInt     `json:"parse"`
	Jx        FlexInt     `json:"jx"`
	Flag      string      `json:"flag"`
	Danmaku   FlexDanmaku `json:"danmaku"`
	Format    string      `json:"format"`
	URL       URL         `json:"url"`
	Key       string      `json:"key"`
	Click     string      `json:"click"`
	Drm       *Drm        `json:"drm"`
	Subs      []Sub       `json:"subs"`
	Artwork   string      `json:"artwork"`
	Desc      string      `json:"desc"`
	Position  FlexInt     `json:"position"`
	PageCount FlexInt     `json:"pagecount"`
	Code      FlexInt     `json:"code"`
	Msg       FlexString  `json:"msg"`
	Success   bool        `json:"-"`
}

// Sub 外挂字幕轨。
type Sub struct {
	URL    string `json:"url"`
	Name   string `json:"name"`
	Lang   string `json:"lang"`
	Format string `json:"format"`
	Flag   int    `json:"flag"`
}

// EffectiveMsg：code!=0 或空 msg → ""（Result.getMsg）。
func (r Result) EffectiveMsg() string {
	msg := strings.TrimSpace(r.Msg.String())
	if msg == "" || (r.Code.Valid && r.Code.Value != 0) {
		return ""
	}
	return msg
}

// CleanDesc 去掉 desc 中多余空白。
func CleanDesc(s string) string {
	s = strings.TrimSpace(s)
	if s == "" {
		return ""
	}
	return strings.Join(strings.Fields(s), " ")
}

// Type 分类。
type Type struct {
	TypeID   FlexString `json:"type_id"`
	TypeName string     `json:"type_name"`
	TypeFlag string     `json:"type_flag"`
	Filters  []Filter   `json:"filters,omitempty"`
	Selected bool       `json:"-"`
}

// UnmarshalJSON type_id/id、type_name/name 互为别名。
func (t *Type) UnmarshalJSON(data []byte) error {
	data = bytes.TrimSpace(data)
	if len(data) == 0 || string(data) == "null" {
		*t = Type{}
		return nil
	}
	var raw struct {
		TypeID   FlexString `json:"type_id"`
		ID       FlexString `json:"id"`
		TypeName string     `json:"type_name"`
		Name     string     `json:"name"`
		TypeFlag string     `json:"type_flag"`
		Filters  []Filter   `json:"filters"`
	}
	if err := json.Unmarshal(data, &raw); err != nil {
		return err
	}
	id := raw.TypeID
	if strings.TrimSpace(id.String()) == "" {
		id = raw.ID
	}
	name := raw.TypeName
	if strings.TrimSpace(name) == "" {
		name = raw.Name
	}
	*t = Type{
		TypeID:   id,
		TypeName: name,
		TypeFlag: raw.TypeFlag,
		Filters:  raw.Filters,
	}
	return nil
}

func HomeType() Type {
	return Type{TypeID: "home", TypeName: "推荐", Selected: true}
}

// Filter 筛选条件。
type Filter struct {
	Key   string       `json:"key"`
	Name  string       `json:"name"`
	Init  FlexString   `json:"init"`
	Value []FilterItem `json:"value"`
}

type FilterItem struct {
	N string     `json:"n"`
	V FlexString `json:"v"`
}

// FilterMap 值可为单个 Filter 对象或 Filter 数组。
type FilterMap map[string][]Filter

func (m *FilterMap) UnmarshalJSON(data []byte) error {
	data = bytes.TrimSpace(data)
	if len(data) == 0 || string(data) == "null" {
 *m = nil
		return nil
	}
	var raw map[string]json.RawMessage
	if err := json.Unmarshal(data, &raw); err != nil {
		return err
	}
	out := make(FilterMap, len(raw))
	for k, v := range raw {
		v = bytes.TrimSpace(v)
		if len(v) == 0 || string(v) == "null" {
			continue
		}
		if v[0] == '{' {
			var one Filter
			if err := json.Unmarshal(v, &one); err != nil {
				return err
			}
			out[k] = []Filter{one}
			continue
		}
		var arr []Filter
		if err := json.Unmarshal(v, &arr); err != nil {
			return err
		}
		out[k] = arr
	}
	*m = out
	return nil
}

// URL 播放地址（支持单地址、字符串数组、交替 name/url 数组，或 {values,position} 对象）。
type URL struct {
	URLs     []string
	Names    []string
	Position int // Url.position，默认 0
}

func (u *URL) UnmarshalJSON(data []byte) error {
	data = bytes.TrimSpace(data)
	if len(data) == 0 || string(data) == "null" {
		return nil
	}
	var s string
	if err := json.Unmarshal(data, &s); err == nil {
		u.URLs = []string{s}
		return nil
	}
	if len(data) > 0 && data[0] == '{' {
		var obj struct {
			Values   []struct {
				N string `json:"n"`
				V string `json:"v"`
			} `json:"values"`
			Position int `json:"position"`
		}
		if err := json.Unmarshal(data, &obj); err != nil {
			return nil
		}
		for _, it := range obj.Values {
			u.Names = append(u.Names, it.N)
			u.URLs = append(u.URLs, it.V)
		}
		u.Position = obj.Position
		if u.Position < 0 {
			u.Position = 0
		}
		if len(u.URLs) > 0 && u.Position >= len(u.URLs) {
			u.Position = len(u.URLs) - 1
		}
		if u.Position > 0 && u.Position < len(u.URLs) {
			// 把默认项调到首位，方便 qualIdx=0
			u.URLs[0], u.URLs[u.Position] = u.URLs[u.Position], u.URLs[0]
			if len(u.Names) == len(u.URLs) {
				u.Names[0], u.Names[u.Position] = u.Names[u.Position], u.Names[0]
			}
			u.Position = 0
		}
		return nil
	}
	var arr []json.RawMessage
	if err := json.Unmarshal(data, &arr); err != nil {
		return nil
	}
	// UrlAdapter.convert：严格成对 name/url，奇数尾丢弃。
	if len(arr) >= 2 {
		var names, urls []string
		for i := 0; i+1 < len(arr); i += 2 {
			var n, v string
			if json.Unmarshal(arr[i], &n) != nil || json.Unmarshal(arr[i+1], &v) != nil {
				names, urls = nil, nil
				break
			}
			names = append(names, n)
			urls = append(urls, v)
		}
		if len(urls) > 0 {
			u.Names = names
			u.URLs = urls
			return nil
		}
	}
	var strs []string
	if err := json.Unmarshal(data, &strs); err == nil {
		u.URLs = strs
	}
	return nil
}

// DecodeResultJSON 反序列化 JSON Result。
// 先走 lenientjson（单引号/无引号 key/尾逗号等），再严格 Unmarshal。
func DecodeResultJSON(raw string) (Result, error) {
	var result Result
	if err := lenientjson.Unmarshal([]byte(raw), &result); err != nil {
		return Result{}, err
	}
	return result, nil
}

// Collect 搜索结果分组。
type Collect struct {
	Name      string
	Site      *Site
	List      []Vod
	Activated bool
}

func CollectAll() Collect {
	return Collect{Name: "全部", Activated: true}
}
