package m3u8

// FilterMode 广告过滤档位。
type FilterMode string

const (
	// ModeSmart：结构过滤（DISCONTINUITY 段组）；无改动或回滚时再温和去断点。
	ModeSmart FilterMode = "smart"
	// ModeMild：只删 #EXT-X-DISCONTINUITY 标记，不删切片（最保守兜底）。
	ModeMild FilterMode = "mild"
)

// FilterConfig 广告过滤参数。
// 主路径思路按（按 DISCONTINUITY 分段，不靠序号）；
// 温和档只去断点标记。
type FilterConfig struct {
	Mode FilterMode `json:"mode"`

	// KeepMinDuration 段组总时长 ≥ 此值（秒）视为正片，保留。
	KeepMinDuration float64 `json:"keepMinDuration"`
	// UniformShortMax 组内 EXTINF 全相同且总和 < 此值 → 删。
	UniformShortMax float64 `json:"uniformShortMax"`
	// MaxRemoveDuration 删掉总时长超过此值则整单回滚（防误杀成几十秒）。
	MaxRemoveDuration float64 `json:"maxRemoveDuration"`
	// UseLastModified 为 true 时，对每组抽样 HEAD，用 Last-Modified 簇识别广告。
	UseLastModified bool `json:"useLastModified"`
}

// DefaultConfig 默认：智能档 + 463326 量级阈值。
func DefaultConfig() FilterConfig {
	return FilterConfig{
		Mode:              ModeSmart,
		KeepMinDuration:   60,
		UniformShortMax:   10,
		MaxRemoveDuration: 120,
		UseLastModified:   true,
	}
}

func (c FilterConfig) normalized() FilterConfig {
	out := c
	switch out.Mode {
	case ModeSmart, ModeMild:
	default:
		out.Mode = ModeSmart
	}
	if out.KeepMinDuration <= 0 {
		out.KeepMinDuration = 60
	}
	if out.UniformShortMax <= 0 {
		out.UniformShortMax = 10
	}
	if out.MaxRemoveDuration <= 0 {
		out.MaxRemoveDuration = 120
	}
	return out
}
