package model

import (
	"bytes"
	"encoding/json"
)

// FlexString 兼容 JSON 里 string / number / bool / object / array。
// py/js 源常把 vod_id、vod_year 等写成数字，兼容 Gson 宽松反序列化。
type FlexString string

func (f *FlexString) UnmarshalJSON(b []byte) error {
	b = bytes.TrimSpace(b)
	if len(b) == 0 || bytes.Equal(b, []byte("null")) {
		*f = ""
		return nil
	}
	if b[0] == '"' {
		var s string
		if err := json.Unmarshal(b, &s); err != nil {
			return err
		}
		*f = FlexString(s)
		return nil
	}
	// number / bool
	if b[0] == '-' || b[0] == '+' || (b[0] >= '0' && b[0] <= '9') || b[0] == 't' || b[0] == 'f' {
		*f = FlexString(string(b))
		return nil
	}
	// object / array → 原样紧凑 JSON
	var buf bytes.Buffer
	if err := json.Compact(&buf, b); err != nil {
		*f = FlexString(b)
		return nil
	}
	*f = FlexString(buf.String())
	return nil
}

func (f FlexString) MarshalJSON() ([]byte, error) {
	return json.Marshal(string(f))
}

func (f FlexString) String() string { return string(f) }
