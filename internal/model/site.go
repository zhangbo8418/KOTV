package model

// Site 站源配置。
type Site struct {
	Key         string     `json:"key"`
	Name        string     `json:"name"`
	Type        FlexInt    `json:"type"`
	API         string     `json:"api"`
	Searchable  FlexInt    `json:"searchable"`
	Changeable  FlexInt    `json:"changeable"`
	PlayURL     string     `json:"playUrl"`
	QuickSearch FlexInt    `json:"quickSearch"`
	Indexs      FlexInt    `json:"indexs"`
	PlayerType  FlexString `json:"playerType"`
	Hide        FlexInt    `json:"hide"`
	Categories  []string   `json:"categories"`
	Ext         FlexString `json:"ext"`
	Style       *Style     `json:"style"`
	Timeout     FlexInt    `json:"timeout"`
	Jar         string     `json:"jar"`
	Header      FlexHeader `json:"header"`
	Click       string     `json:"click"`
	ID          int        `json:"-"`
}

func (s Site) TypeID() int {
	if s.Type.Valid {
		return s.Type.Value
	}
	return 0
}

func (s Site) IsSearchable() bool {
	if !s.Searchable.Valid {
		return true // 未声明时默认可搜
	}
	return s.Searchable.Value == 1
}

func (s Site) IsChangeable() bool {
	if !s.Changeable.Valid {
		return true
	}
	return s.Changeable.Value == 1
}

func (s Site) IsHide() bool {
	return s.Hide.Valid && s.Hide.Value == 1
}

// IsIndex 索引站（如豆瓣）点进条目应去搜索，而非本站详情。
func (s Site) IsIndex() bool {
	return s.Indexs.Valid && s.Indexs.Value == 1
}

// CanToggleSearchable ：searchable==0 表示配置锁定，不可改。
func (s Site) CanToggleSearchable() bool {
	return !s.Searchable.Valid || s.Searchable.Value != 0
}

// CanToggleChangeable ：changeable==0 表示配置锁定，不可改。
func (s Site) CanToggleChangeable() bool {
	return !s.Changeable.Valid || s.Changeable.Value != 0
}

// SetSearchable Site.setSearchable(boolean)：开=1，关=2。
func (s *Site) SetSearchable(on bool) bool {
	if !s.CanToggleSearchable() {
		return false
	}
	v := 2
	if on {
		v = 1
	}
	s.Searchable = FlexInt{Valid: true, Value: v}
	return true
}

// SetChangeable Site.setChangeable(boolean)：开=1，关=2。
func (s *Site) SetChangeable(on bool) bool {
	if !s.CanToggleChangeable() {
		return false
	}
	v := 2
	if on {
		v = 1
	}
	s.Changeable = FlexInt{Valid: true, Value: v}
	return true
}

// Style 展示样式（Style.ratio 为 float，配置里也可能是字符串）。
type Style struct {
	Type  FlexString `json:"type"`
	Ratio FlexString `json:"ratio"`
}
