package m3u8

import (
	"net/url"
	"path"
	"regexp"
	"strconv"
	"strings"
)

// Filter 基于 ltxlong M3U8-Filter-Ad-Script (MIT) 的广告过滤实现。
type Filter struct {
	cfg FilterConfig

	tsNameLen          int
	firstExtinfRow     string
	theExtinfJudgeRowN int
	theSameExtinfNameN int
	prevTsNameIndex    int
	firstTsNameIndex   int
	tsType             int // 0 数字递增 / 1 非数字名 / 2 暴力
	theExtXMode        int
	filteredAdCount    int
}

func NewFilter(cfg FilterConfig) *Filter {
	if cfg.TsNameLenExtend == 0 && cfg.TheExtinfBenchmarkN == 0 && !cfg.ViolentFilterModeFlag {
		cfg = DefaultConfig()
	}
	if cfg.TheExtinfBenchmarkN == 0 {
		cfg.TheExtinfBenchmarkN = 5
	}
	return &Filter{cfg: cfg, prevTsNameIndex: -1, firstTsNameIndex: -1}
}

func (f *Filter) FilteredAdCount() int { return f.filteredAdCount }

var tsNumberRe = regexp.MustCompile(`(\d+)\.ts`)

// mediaBase 只取切片文件名再识别。绝对化后的 URL 若在主机名里带 .ts（如 cdn01.ts.com），
// 对整串做 indexOf(`\.ts`) / `(\d+)\.ts` 会误把域名当成序号，正片几乎删光只剩几十秒。
func mediaBase(line string) string {
	trim := strings.TrimSpace(line)
	if trim == "" || strings.HasPrefix(trim, "#") {
		return trim
	}
	if i := strings.IndexAny(trim, "?#"); i >= 0 {
		trim = trim[:i]
	}
	if strings.Contains(trim, "://") {
		if u, err := url.Parse(trim); err == nil && u.Path != "" {
			return path.Base(u.Path)
		}
	}
	return path.Base(trim)
}

func tsPrefixLen(line string) int {
	base := mediaBase(line)
	i := strings.Index(base, ".ts")
	if i <= 0 {
		return -1
	}
	return i
}

func extractNumberBeforeTs(s string) (int, bool) {
	m := tsNumberRe.FindStringSubmatch(mediaBase(s))
	if len(m) < 2 {
		return 0, false
	}
	n, err := strconv.Atoi(m[1])
	return n, err == nil
}

func lineHasTs(line string) bool {
	return tsPrefixLen(line) > 0
}

// FilterLines 过滤广告分片行。
func (f *Filter) FilterLines(lines []string) []string {
	f.filteredAdCount = 0
	f.tsNameLen = 0
	f.firstExtinfRow = ""
	f.theExtinfJudgeRowN = 0
	f.theSameExtinfNameN = 0
	f.prevTsNameIndex = -1
	f.firstTsNameIndex = -1
	f.tsType = 0
	f.theExtXMode = 0

	if f.cfg.ViolentFilterModeFlag {
		f.tsType = 2
	} else {
		f.detectTsType(lines)
	}

	result := make([]string, 0, len(lines))
	i := 0
	for i < len(lines) {
		line := lines[i]
		switch f.tsType {
		case 0:
			if f.handleMode0(lines, &i, &result) {
				continue
			}
		case 1:
			if f.handleMode1(lines, &i, &result) {
				continue
			}
		default:
			if strings.HasPrefix(line, "#EXT-X-DISCONTINUITY") {
				if i > 0 && strings.HasPrefix(lines[i-1], "#EXT-X-PLAYLIST-TYPE") {
					result = append(result, line)
					i++
					continue
				}
				f.filteredAdCount++
				i++
				continue
			}
		}
		result = append(result, line)
		i++
	}
	return result
}

func (f *Filter) detectTsType(lines []string) {
	theNormalIntTsN := 0
	theDiffIntTsN := 0
	for i, line := range lines {
		if f.theExtinfJudgeRowN == 0 && strings.HasPrefix(line, "#EXTINF") {
			f.firstExtinfRow = line
			f.theExtinfJudgeRowN++
		} else if f.theExtinfJudgeRowN == 1 && strings.HasPrefix(line, "#EXTINF") {
			if line != f.firstExtinfRow {
				f.firstExtinfRow = ""
			}
			f.theExtinfJudgeRowN++
		}

		theTsNameLen := tsPrefixLen(line)
		if theTsNameLen > 0 {
			if f.theExtinfJudgeRowN == 1 {
				f.tsNameLen = theTsNameLen
			}
			tsNameIndex, ok := extractNumberBeforeTs(line)
			if !ok {
				if f.theExtinfJudgeRowN == 1 {
					f.tsType = 1
				} else if f.theExtinfJudgeRowN == 2 && (f.tsType == 1 || theTsNameLen == f.tsNameLen) {
					f.tsType = 1
					return
				} else {
					theDiffIntTsN++
				}
			} else {
				if theNormalIntTsN == 0 {
					f.firstTsNameIndex = tsNameIndex
					f.prevTsNameIndex = f.firstTsNameIndex - 1
				}
				if theTsNameLen != f.tsNameLen {
					if theDiffIntTsN > 0 {
						if tsNameIndex == f.prevTsNameIndex+1 {
							f.tsType = 0
							f.prevTsNameIndex = f.firstTsNameIndex - 1
							return
						}
						f.tsType = 2
						return
					}
					theDiffIntTsN++
				} else {
					if theDiffIntTsN > 0 {
						if tsNameIndex == f.prevTsNameIndex+1 {
							f.tsType = 0
							f.prevTsNameIndex = f.firstTsNameIndex - 1
							return
						}
						f.tsType = 2
						return
					}
					theNormalIntTsN++
					f.prevTsNameIndex = tsNameIndex
				}
			}
		}
		if i == len(lines)-1 {
			f.tsType = 2
		}
	}
}

func (f *Filter) handleMode0(lines []string, i *int, result *[]string) bool {
	line := lines[*i]
	if strings.HasPrefix(line, "#EXT-X-DISCONTINUITY") && *i+2 < len(lines) {
		if *i > 0 && strings.HasPrefix(lines[*i-1], "#EXT-X-") {
			*result = append(*result, line)
			*i++
			return true
		}
		theTsNameLen := tsPrefixLen(lines[*i+2])
		if theTsNameLen > 0 {
			if theTsNameLen-f.tsNameLen > f.cfg.TsNameLenExtend {
				f.filteredAdCount++
				if *i+3 < len(lines) && strings.HasPrefix(lines[*i+3], "#EXT-X-DISCONTINUITY") {
					*i += 4
				} else {
					*i += 3
				}
				return true
			}
			f.tsNameLen = theTsNameLen
			theTsNameIndex, ok := extractNumberBeforeTs(lines[*i+2])
			if ok && theTsNameIndex != f.prevTsNameIndex+1 {
				f.filteredAdCount++
				if *i+3 < len(lines) && strings.HasPrefix(lines[*i+3], "#EXT-X-DISCONTINUITY") {
					*i += 4
				} else {
					*i += 3
				}
				return true
			}
		}
	}

	if strings.HasPrefix(line, "#EXTINF") && *i+1 < len(lines) {
		theTsNameLen := tsPrefixLen(lines[*i+1])
		if theTsNameLen > 0 {
			if theTsNameLen-f.tsNameLen > f.cfg.TsNameLenExtend {
				f.filteredAdCount++
				if *i+2 < len(lines) && strings.HasPrefix(lines[*i+2], "#EXT-X-DISCONTINUITY") {
					*i += 3
				} else {
					*i += 2
				}
				return true
			}
			f.tsNameLen = theTsNameLen
			theTsNameIndex, ok := extractNumberBeforeTs(lines[*i+1])
			if ok {
				if theTsNameIndex == f.prevTsNameIndex+1 {
					f.prevTsNameIndex++
				} else {
					f.filteredAdCount++
					if *i+2 < len(lines) && strings.HasPrefix(lines[*i+2], "#EXT-X-DISCONTINUITY") {
						*i += 3
					} else {
						*i += 2
					}
					return true
				}
			}
		}
	}
	return false
}

func (f *Filter) handleMode1(lines []string, i *int, result *[]string) bool {
	line := lines[*i]
	if strings.HasPrefix(line, "#EXTINF") {
		if line == f.firstExtinfRow && f.theSameExtinfNameN <= f.cfg.TheExtinfBenchmarkN && f.theExtXMode == 0 {
			f.theSameExtinfNameN++
		} else {
			f.theExtXMode = 1
		}
		if f.theSameExtinfNameN > f.cfg.TheExtinfBenchmarkN {
			f.theExtXMode = 1
		}
	}
	if strings.HasPrefix(line, "#EXT-X-DISCONTINUITY") {
		if *i > 0 && strings.HasPrefix(lines[*i-1], "#EXT-X-PLAYLIST-TYPE") {
			*result = append(*result, line)
			*i++
			return true
		}
		if *i+2 < len(lines) && strings.HasPrefix(lines[*i+1], "#EXTINF") && lineHasTs(lines[*i+2]) {
			cond := false
			if f.theExtXMode == 1 {
				cond = lines[*i+1] != f.firstExtinfRow && f.theSameExtinfNameN > f.cfg.TheExtinfBenchmarkN
			}
			f.filteredAdCount++
			if *i+3 < len(lines) && strings.HasPrefix(lines[*i+3], "#EXT-X-DISCONTINUITY") && cond {
				*i += 4
			} else {
				*i++
			}
			return true
		}
	}
	return false
}

// Process 对完整 m3u8 文本做过滤。
func (f *Filter) Process(content string) string {
	lines := strings.Split(strings.ReplaceAll(strings.ReplaceAll(content, "\r\n", "\n"), "\r", ""), "\n")
	return strings.Join(f.FilterLines(lines), "\n")
}

// IsMasterPlaylist 是否为多码率主列表。
func IsMasterPlaylist(content string) bool {
	return strings.Contains(content, "#EXT-X-STREAM-INF")
}
