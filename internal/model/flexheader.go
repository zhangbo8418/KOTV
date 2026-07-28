package model

import (
	"bytes"
	"encoding/json"
)

// FlexHeader 兼容 header 为 object 或 JSON 字符串。
type FlexHeader map[string]string

func (h *FlexHeader) UnmarshalJSON(b []byte) error {
	b = bytes.TrimSpace(b)
	if len(b) == 0 || bytes.Equal(b, []byte("null")) {
		*h = nil
		return nil
	}
	if b[0] == '"' {
		var s string
		if err := json.Unmarshal(b, &s); err != nil {
			return err
		}
		s = string(bytes.TrimSpace([]byte(s)))
		if s == "" {
			*h = nil
			return nil
		}
		var m map[string]string
		if err := json.Unmarshal([]byte(s), &m); err != nil {
			*h = nil
			return nil
		}
		*h = m
		return nil
	}
	var m map[string]string
	if err := json.Unmarshal(b, &m); err != nil {
		// 有时 value 不是 string
		var anyMap map[string]any
		if err2 := json.Unmarshal(b, &anyMap); err2 != nil {
			*h = nil
			return nil
		}
		m = make(map[string]string, len(anyMap))
		for k, v := range anyMap {
			switch t := v.(type) {
			case string:
				m[k] = t
			default:
				raw, _ := json.Marshal(t)
				m[k] = string(raw)
			}
		}
	}
	*h = m
	return nil
}
