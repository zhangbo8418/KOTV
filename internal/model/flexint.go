package model

import (
	"bytes"
	"encoding/json"
	"strconv"
	"strings"
)

// FlexInt 兼容 JSON number / string / bool。
type FlexInt struct {
	Valid bool
	Value int
}

func (f *FlexInt) UnmarshalJSON(b []byte) error {
	b = bytes.TrimSpace(b)
	if len(b) == 0 || bytes.Equal(b, []byte("null")) {
		*f = FlexInt{}
		return nil
	}
	if b[0] == '"' {
		var s string
		if err := json.Unmarshal(b, &s); err != nil {
			return err
		}
		s = strings.TrimSpace(s)
		if s == "" {
			*f = FlexInt{}
			return nil
		}
		n, err := strconv.Atoi(s)
		if err != nil {
			*f = FlexInt{}
			return nil
		}
		*f = FlexInt{Valid: true, Value: n}
		return nil
	}
	if bytes.Equal(b, []byte("true")) {
		*f = FlexInt{Valid: true, Value: 1}
		return nil
	}
	if bytes.Equal(b, []byte("false")) {
		*f = FlexInt{Valid: true, Value: 0}
		return nil
	}
	var n int
	if err := json.Unmarshal(b, &n); err != nil {
		*f = FlexInt{}
		return nil
	}
	*f = FlexInt{Valid: true, Value: n}
	return nil
}

func (f FlexInt) MarshalJSON() ([]byte, error) {
	if !f.Valid {
		return []byte("null"), nil
	}
	return json.Marshal(f.Value)
}

func (f *FlexInt) Ptr() *int {
	if f == nil || !f.Valid {
		return nil
	}
	v := f.Value
	return &v
}

func (f FlexInt) Is(v int) bool { return f.Valid && f.Value == v }
