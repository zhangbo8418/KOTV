package model

import (
	"bytes"
	"encoding/json"
	"strings"
)

// LiveList 点播/直播 JSON 里的 lives：对象数组、单个对象、或 URL 字符串。
type LiveList []Live

func (l *LiveList) UnmarshalJSON(b []byte) error {
	b = bytes.TrimSpace(b)
	if len(b) == 0 || bytes.Equal(b, []byte("null")) {
		*l = nil
		return nil
	}
	if b[0] == '"' {
		var s string
		if err := json.Unmarshal(b, &s); err != nil {
			return err
		}
		s = strings.TrimSpace(s)
		if s == "" {
			*l = nil
			return nil
		}
		*l = []Live{{URL: s}}
		return nil
	}
	if b[0] == '{' {
		var one Live
		if err := json.Unmarshal(b, &one); err != nil {
			return err
		}
		*l = []Live{one}
		return nil
	}
	var raw []json.RawMessage
	if err := json.Unmarshal(b, &raw); err != nil {
		*l = nil
		return nil
	}
	out := make([]Live, 0, len(raw))
	for _, item := range raw {
		item = bytes.TrimSpace(item)
		if len(item) == 0 {
			continue
		}
		if item[0] == '"' {
			var s string
			if json.Unmarshal(item, &s) != nil {
				continue
			}
			s = strings.TrimSpace(s)
			if s != "" {
				out = append(out, Live{URL: s})
			}
			continue
		}
		if item[0] == '{' {
			var one Live
			if json.Unmarshal(item, &one) != nil {
				continue
			}
			out = append(out, one)
		}
	}
	*l = out
	return nil
}

func (l LiveList) MarshalJSON() ([]byte, error) {
	return json.Marshal([]Live(l))
}
