package model

// Depot 多仓索引条目（urls[] 中的 name + url）。
type Depot struct {
	URL  string `json:"url"`
	Name string `json:"name"`
}

// DisplayName 优先用接口名，否则回落 URL。
func (d Depot) DisplayName() string {
	if d.Name != "" {
		return d.Name
	}
	return d.URL
}
