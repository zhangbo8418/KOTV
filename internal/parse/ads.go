package parse

import (
	"net/url"
	"strings"
	"sync"

	"github.com/bobo/KOTV/internal/model"
	"github.com/bobo/KOTV/internal/util"
)

// RuleConfig：vod + live 的 ads/rules 合并后供嗅探使用。
var (
	ruleMu    sync.RWMutex
	vodAds    []string
	liveAds   []string
	vodRules  []model.Rule
	liveRules []model.Rule
	adsList   []string
	rulesList []model.Rule
)

// SetAds 兼容旧调用：等同 SetVodAds。
func SetAds(ads []string) {
	SetVodAds(ads)
}

// SetVodAds 设置点播配置广告域名。
func SetVodAds(ads []string) {
	ruleMu.Lock()
	vodAds = cleanAds(ads)
	refreshLocked()
	ruleMu.Unlock()
}

// SetLiveAds 设置直播配置广告域名。
func SetLiveAds(ads []string) {
	ruleMu.Lock()
	liveAds = cleanAds(ads)
	refreshLocked()
	ruleMu.Unlock()
}

// SetVodRules 设置点播配置规则。
func SetVodRules(rules []model.Rule) {
	ruleMu.Lock()
	vodRules = append([]model.Rule(nil), rules...)
	refreshLocked()
	ruleMu.Unlock()
}

// SetLiveRules 设置直播配置规则。
func SetLiveRules(rules []model.Rule) {
	ruleMu.Lock()
	liveRules = append([]model.Rule(nil), rules...)
	refreshLocked()
	ruleMu.Unlock()
}

// GetAds 返回合并后的广告域名（vod + live）。
func GetAds() []string {
	ruleMu.RLock()
	defer ruleMu.RUnlock()
	return append([]string(nil), adsList...)
}

// GetRules 返回合并后的规则（vod + live）。
func GetRules() []model.Rule {
	ruleMu.RLock()
	defer ruleMu.RUnlock()
	return append([]model.Rule(nil), rulesList...)
}

// IsAdHost 判断 host 是否命中 ads 黑名单。
func IsAdHost(host string) bool {
	host = strings.ToLower(strings.TrimSpace(host))
	if host == "" {
		return false
	}
	ruleMu.RLock()
	defer ruleMu.RUnlock()
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

func cleanAds(ads []string) []string {
	cleaned := make([]string, 0, len(ads))
	for _, a := range ads {
		a = strings.TrimSpace(a)
		if a != "" {
			cleaned = append(cleaned, a)
		}
	}
	return cleaned
}

func refreshLocked() {
	adsList = append(append([]string(nil), vodAds...), liveAds...)
	rulesList = append(append([]model.Rule(nil), vodRules...), liveRules...)
}
