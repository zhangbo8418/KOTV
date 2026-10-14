package database

import "strings"

// NormalizeExternalHistoryKey 把外部 site@@@vodId@@@cid / site$$$vodId 归一成 vodId@site。
func NormalizeExternalHistoryKey(key string) string {
	key = strings.TrimSpace(key)
	if key == "" {
		return ""
	}
	if strings.Contains(key, "@@@") {
		parts := strings.Split(key, "@@@")
		if len(parts) >= 2 && parts[0] != "" && parts[1] != "" {
			return parts[1] + "@" + parts[0]
		}
	}
	if strings.Contains(key, "$$$") {
		parts := strings.SplitN(key, "$$$", 2)
		if len(parts) == 2 && parts[0] != "" && parts[1] != "" {
			return parts[1] + "@" + parts[0]
		}
	}
	return key
}

// ExternalHistoryKey 把 vodId@site 写成同步协议的 site$$$vodId。
func ExternalHistoryKey(key string) string {
	key = strings.TrimSpace(key)
	if i := strings.LastIndex(key, "@"); i > 0 {
		return key[i+1:] + "$$$" + key[:i]
	}
	return key
}
