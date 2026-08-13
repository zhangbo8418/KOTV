package live

import (
	"encoding/json"
	"strings"

	"github.com/bobo/KOTV/internal/model"
)

// ConfigMeta LiveConfig 根字段：ads / rules / lives。
type ConfigMeta struct {
	Ads   []string     `json:"ads"`
	Rules []model.Rule `json:"rules"`
	Lives []model.Live `json:"lives"`
}

// ParseConfigMeta 若文本是直播配置 JSON 对象（含 ads/rules/lives 任一），则解析；否则 ok=false。
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
	if !hasLives && !hasAds && !hasRules {
		return ConfigMeta{}, false
	}
	var meta ConfigMeta
	if err := json.Unmarshal([]byte(trimmed), &meta); err != nil {
		return ConfigMeta{}, false
	}
	return meta, true
}
