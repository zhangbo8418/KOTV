package model

import "encoding/json"

// Api 点播配置根对象，对应 CatVod 配置 JSON。
type Api struct {
	ID        string          `json:"-"`
	Spider    string          `json:"spider"`
	Sites     []Site          `json:"sites"`
	Lives     []Live          `json:"lives"`
	Parses    []Parse         `json:"parses"`
	Rules     []Rule          `json:"rules"`
	Flags     []string        `json:"flags"`
	Ads       []string        `json:"ads"`
	Headers   json.RawMessage `json:"headers"`
	Proxy     json.RawMessage `json:"proxy"`
	Hosts     json.RawMessage `json:"hosts"`
	Doh       json.RawMessage `json:"doh"`
	Wallpaper string          `json:"wallpaper"`
	Logo      string          `json:"logo"`
	URL       string          `json:"-"`
	Data      string          `json:"-"`
	Ref       int             `json:"-"`
}

// Parse 二次解析配置。
type Parse struct {
	Name string     `json:"name"`
	Type FlexInt    `json:"type"`
	URL  string     `json:"url"`
	Ext  FlexString `json:"ext"`
}

func (p Parse) TypeID() int {
	if p.Type.Valid {
		return p.Type.Value
	}
	return 0
}

// Rule 规则配置。
type Rule struct {
	Name    string   `json:"name"`
	Hosts   []string `json:"hosts"`
	Regex   []string `json:"regex"`
	Script  []string `json:"script"`
	Exclude []string `json:"exclude"`
}
