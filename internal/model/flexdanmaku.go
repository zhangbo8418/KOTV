package model

import (
	"bytes"
	"encoding/json"
	"strings"
)

// FlexDanmaku 可为 URL 字符串、对象 {url}、或对象数组。
// 整字段若用 string 接数组会导致整个 Result 反序列化失败 → 首页/分类变空。
type FlexDanmaku string

func (d *FlexDanmaku) UnmarshalJSON(b []byte) error {
	b = bytes.TrimSpace(b)
	if len(b) == 0 || bytes.Equal(b, []byte("null")) {
		*d = ""
		return nil
	}
	switch b[0] {
	case '"':
		var s string
		if err := json.Unmarshal(b, &s); err != nil {
			return err
		}
		*d = FlexDanmaku(strings.TrimSpace(s))
		return nil
	case '{':
		*d = FlexDanmaku(danmakuURLFromObj(b))
		return nil
	case '[':
		var arr []json.RawMessage
		if err := json.Unmarshal(b, &arr); err != nil {
			*d = ""
			return nil
		}
		for _, item := range arr {
			item = bytes.TrimSpace(item)
			if len(item) == 0 || bytes.Equal(item, []byte("null")) {
				continue
			}
			if item[0] == '"' {
				var s string
				if json.Unmarshal(item, &s) == nil {
					if s = strings.TrimSpace(s); s != "" {
						*d = FlexDanmaku(s)
						return nil
					}
				}
				continue
			}
			if u := danmakuURLFromObj(item); u != "" {
				*d = FlexDanmaku(u)
				return nil
			}
		}
		*d = ""
		return nil
	default:
		// 数字等：尽量当字符串保留
		*d = FlexDanmaku(string(b))
		return nil
	}
}

func danmakuURLFromObj(b []byte) string {
	var obj struct {
		URL  string `json:"url"`
		Name string `json:"name"`
	}
	if json.Unmarshal(b, &obj) != nil {
		return ""
	}
	if u := strings.TrimSpace(obj.URL); u != "" {
		return u
	}
	return strings.TrimSpace(obj.Name)
}

func (d FlexDanmaku) MarshalJSON() ([]byte, error) {
	return json.Marshal(string(d))
}

func (d FlexDanmaku) String() string { return string(d) }
