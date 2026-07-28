package parse

import (
	"net/url"
	"strings"
	"sync"

	"github.com/bobo/KOTV/internal/util"
)

var (
	adsMu   sync.RWMutex
	adsList []string
)

// SetAds 设置配置里的广告域名黑名单（用于网页嗅探拦截）。
func SetAds(ads []string) {
	cleaned := make([]string, 0, len(ads))
	for _, a := range ads {
		a = strings.TrimSpace(a)
		if a != "" {
			cleaned = append(cleaned, a)
		}
	}
	adsMu.Lock()
	adsList = cleaned
	adsMu.Unlock()
}

// IsAdHost 判断 host 是否命中 ads 黑名单。
func IsAdHost(host string) bool {
	host = strings.ToLower(strings.TrimSpace(host))
	if host == "" {
		return false
	}
	adsMu.RLock()
	defer adsMu.RUnlock()
	for _, ad := range adsList {
		if util.ContainOrMatch(host, strings.ToLower(ad)) {
			return true
		}
	}
	return false
}

// IsAdURL 判断 URL 的 host 是否为广告域名。
func IsAdURL(raw string) bool {
	u, err := url.Parse(strings.TrimSpace(raw))
	if err != nil || u.Hostname() == "" {
		return false
	}
	return IsAdHost(u.Hostname())
}
