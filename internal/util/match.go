package util

import (
	"regexp"
	"strings"
)

// ContainOrMatch 文本包含 pattern，或整串匹配 pattern 正则（与 CatVod Util.containOrMatch 一致）。
func ContainOrMatch(text, pattern string) bool {
	if text == "" || pattern == "" {
		return false
	}
	if strings.Contains(text, pattern) {
		return true
	}
	re, err := regexp.Compile(pattern)
	if err != nil {
		return false
	}
	return re.MatchString(text)
}
