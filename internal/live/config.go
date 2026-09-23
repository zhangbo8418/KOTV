package live

import (
	"encoding/json"
	"strings"

	"github.com/bobo/KOTV/internal/model"
)

// ConfigMeta LiveConfig 根字段：ads / rules / lives / spider / headers / proxy / hosts。
type ConfigMeta struct {
	Ads     []string          `json:"ads"`
	Rules   []model.Rule      `json:"rules"`
	Lives   model.LiveList    `json:"lives"`
	Spider  string            `json:"spider"`
	Headers json.RawMessage   `json:"headers"`
	Proxy   json.RawMessage   `json:"proxy"`
	Hosts   json.RawMessage   `json:"hosts"`
}

// ParseConfigMeta 若文本是直播配置 JSON 对象（含 ads/rules/lives/spider/headers/proxy/hosts 任一），则解析；否则 ok=false。
func ParseConfigMeta(text string) (ConfigMeta, bool) {
	trimmed := strings.TrimSpace(text)
	if !strings.HasPrefix(trimmed, "{") {
		return ConfigMeta{}, false
	}
	var raw map[string]json.RawMessage
	if err := json.Unmarshal([]byte(trimmed), &raw); err != nil {
		return ConfigMeta{}, false
	}
	_, hasLives := raw["lives"]
	_, hasAds := raw["ads"]
	_, hasRules := raw["rules"]
	_, hasSpider := raw["spider"]
	_, hasHeaders := raw["headers"]
	_, hasProxy := raw["proxy"]
	_, hasHosts := raw["hosts"]
	if !hasLives && !hasAds && !hasRules && !hasSpider && !hasHeaders && !hasProxy && !hasHosts {
		return ConfigMeta{}, false
	}
	var meta ConfigMeta
	if err := json.Unmarshal([]byte(trimmed), &meta); err != nil {
		return ConfigMeta{}, false
	}
	return meta, true
}
