package model

import (
	"math"
	"strconv"
	"strings"
)

// ViewStyle 是列表实际使用的展示样式。
type ViewStyle struct {
	Type  string
	Ratio float64
}

func (v ViewStyle) DTO() map[string]any {
	return map[string]any{"type": v.Type, "ratio": v.Ratio}
}

func (v ViewStyle) IsList() bool { return v.Type == "list" }

func (v ViewStyle) IsLand() bool { return v.Type == "rect" && v.Ratio > 1 }

// RectView 矩形默认：宽高比 0.75。
func RectView() ViewStyle { return ViewStyle{Type: "rect", Ratio: 0.75} }

// StyleView 把站点或条目上的 style 对象换成有效样式。
func StyleView(s *Style) (ViewStyle, bool) {
	if s == nil {
		return ViewStyle{}, false
	}
	return styleObjectView(*s), true
}

// ResolveStyle：条目自己的 style，否则 land/circle/ratio，再否则用 fallback。
func (v Vod) ResolveStyle(fallback ViewStyle) ViewStyle {
	if v.Style != nil {
		return styleObjectView(*v.Style)
	}
	if got, ok := viewFromFlags(v.Land.String(), v.Circle.String(), v.Ratio.String()); ok {
		return got
	}
	if strings.TrimSpace(fallback.Type) == "" {
		return RectView()
	}
	return fallback
}

// ListView 横向列表。
func ListView() ViewStyle { return ViewStyle{Type: "list", Ratio: 1} }

// PageViewStyle 列表页样式：有条目时用第一条的有效样式，否则用站点样式，再否则矩形。
func PageViewStyle(list []Vod, site *Style) ViewStyle {
	fb, ok := StyleView(site)
	if !ok {
		fb = RectView()
	}
	return applyFirstStyle(list, fb)
}

// CategoryPageStyle 分类页：目录分类缺省是列表；否则站点样式，再否则分类上的 land/circle/ratio，再否则矩形。
// 有条目时用第一条的有效样式盖过这个缺省。
func CategoryPageStyle(list []Vod, site *Style, folder bool, land, circle, ratio string) ViewStyle {
	fb := RectView()
	switch {
	case folder:
		fb = ListView()
	default:
		if st, ok := StyleView(site); ok {
			fb = st
		} else if st, ok := viewFromFlags(land, circle, ratio); ok {
			fb = st
		}
	}
	return applyFirstStyle(list, fb)
}

func applyFirstStyle(list []Vod, fb ViewStyle) ViewStyle {
	if strings.TrimSpace(fb.Type) == "" {
		fb = RectView()
	}
	if len(list) == 0 {
		return fb
	}
	return list[0].ResolveStyle(fb)
}

// FindType 按 type_id 查找分类。
func FindType(types []Type, tid string) (Type, bool) {
	tid = strings.TrimSpace(tid)
	for _, typ := range types {
		if typ.TypeID.String() == tid {
			return typ, true
		}
	}
	return Type{}, false
}

func styleObjectView(s Style) ViewStyle {
	t := strings.ToLower(strings.TrimSpace(s.Type.String()))
	switch t {
	case "oval", "list", "rect":
	default:
		t = "rect"
	}
	if t == "list" {
		return ViewStyle{Type: "list", Ratio: 1}
	}
	return ViewStyle{Type: t, Ratio: clampViewRatio(parseFlexFloat(s.Ratio.String()), t == "oval")}
}

func viewFromFlags(land, circle, ratio string) (ViewStyle, bool) {
	r := parseFlexFloat(ratio)
	if parseFlexInt(land) == 1 {
		if r == 0 {
			r = 1.33
		}
		return ViewStyle{Type: "rect", Ratio: clampViewRatio(r, false)}, true
	}
	if parseFlexInt(circle) == 1 {
		if r == 0 {
			r = 1
		}
		return ViewStyle{Type: "oval", Ratio: clampViewRatio(r, true)}, true
	}
	return ViewStyle{}, false
}

func clampViewRatio(ratio float64, oval bool) float64 {
	if ratio <= 0 {
		if oval {
			return 1
		}
		return 0.75
	}
	if ratio > 4 {
		return 4
	}
	return ratio
}

func parseFlexFloat(s string) float64 {
	s = strings.TrimSpace(s)
	if s == "" {
		return 0
	}
	f, err := strconv.ParseFloat(s, 64)
	if err != nil || math.IsNaN(f) || math.IsInf(f, 0) {
		return 0
	}
	return f
}

func parseFlexInt(s string) int {
	return int(parseFlexFloat(s))
}
