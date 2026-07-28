package m3u8

// FilterConfig M3U8 过滤配置。
type FilterConfig struct {
	TsNameLenExtend       int  `json:"tsNameLenExtend"`
	TheExtinfBenchmarkN   int  `json:"theExtinfBenchmarkN"`
	ViolentFilterModeFlag bool `json:"violentFilterModeFlag"`
}

func DefaultConfig() FilterConfig {
	return FilterConfig{
		TsNameLenExtend:     1,
		TheExtinfBenchmarkN: 5,
	}
}
