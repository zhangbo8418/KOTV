package model

import (
	"bytes"
	"encoding/json"
	"strings"
)

// DanmakuItem 单条弹幕源。
type DanmakuItem struct {
	Name string `json:"name"`
	URL  string `json:"url"`
}

// FlexDanmaku 可为 URL 字符串、对象 {url,name}、或对象/字符串数组。
type FlexDanmaku struct {
	Items []DanmakuItem
}

func (d *FlexDanmaku) UnmarshalJSON(b []byte) error {
	b = bytes.TrimSpace(b)
	if len(b) == 0 || bytes.Equal(b, []byte("null")) {
		*d = FlexDanmaku{}
		return nil
	}
	switch b[0] {
	case '"':
		var s string
		if err := json.Unmarshal(b, &s); err != nil {
			return err
		}
		s = strings.TrimSpace(s)
		if s != "" {
			d.Items = []DanmakuItem{{URL: s}}
		}
		return nil
	case '{':
		if it, ok := danmakuItemFromObj(b); ok {
			d.Items = []DanmakuItem{it}
		}
		return nil
	case '[':
		var arr []json.RawMessage
		if err := json.Unmarshal(b, &arr); err != nil {
			*d = FlexDanmaku{}
			return nil
		}
		var items []DanmakuItem
		for _, item := range arr {
			item = bytes.TrimSpace(item)
			if len(item) == 0 || bytes.Equal(item, []byte("null")) {
				continue
			}
			if item[0] == '"' {
				var s string
				if json.Unmarshal(item, &s) == nil {
					if s = strings.TrimSpace(s); s != "" {
						items = append(items, DanmakuItem{URL: s})
					}
				}
				continue
			}
			if it, ok := danmakuItemFromObj(item); ok {
				items = append(items, it)
			}
		}
		d.Items = items
		return nil
	default:
		s := strings.TrimSpace(string(b))
		if s != "" {
			d.Items = []DanmakuItem{{URL: s}}
		}
		return nil
	}
}

func danmakuItemFromObj(b []byte) (DanmakuItem, bool) {
	var obj struct {
		URL  string `json:"url"`
		Name string `json:"name"`
	}
	if json.Unmarshal(b, &obj) != nil {
		return DanmakuItem{}, false
	}
	u := strings.TrimSpace(obj.URL)
	n := strings.TrimSpace(obj.Name)
	if u == "" && n != "" && (strings.HasPrefix(n, "http://") || strings.HasPrefix(n, "https://")) {
		u, n = n, ""
	}
	if u == "" {
		return DanmakuItem{}, false
	}
	return DanmakuItem{Name: n, URL: u}, true
}

func (d FlexDanmaku) MarshalJSON() ([]byte, error) {
	if len(d.Items) == 0 {
		return json.Marshal("")
	}
	if len(d.Items) == 1 && d.Items[0].Name == "" {
		return json.Marshal(d.Items[0].URL)
	}
	return json.Marshal(d.Items)
}

func (d FlexDanmaku) String() string {
	if len(d.Items) == 0 {
		return ""
	}
	return d.Items[0].URL
}
