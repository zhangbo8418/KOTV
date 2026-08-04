package util

import (
	"regexp"
	"strings"
)

// ContainOrMatch 文本包含 pattern，或整串匹配 pattern 正则（对齐 Java Util.containOrMatch：
// text.contains(regex) || text.matches(regex)；matches 为整串，非子串）。
func ContainOrMatch(text, pattern string) bool {
	if text == "" || pattern == "" {
		return false
	}
	if strings.Contains(text, pattern) {
		return true
	}
	re, err := regexp.Compile("^(?:" + pattern + ")$")
	if err != nil {
		return false
	}
	return re.MatchString(text)
}
