package model

import (
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"strings"
)

// Drm 播放 DRM 描述（bean.Drm / #KODIPROP）。
type Drm struct {
	Key      string            `json:"key"`
	Type     string            `json:"type"`
	ForceKey bool              `json:"forceKey"`
	Header   map[string]string `json:"header"`
}

// Scheme 归一化类型：clearkey / widevine / playready / ""。
func (d *Drm) Scheme() string {
	if d == nil {
		return ""
	}
	t := strings.ToLower(d.Type)
	switch {
	case strings.Contains(t, "clearkey"):
		return "clearkey"
	case strings.Contains(t, "widevine"):
		return "widevine"
	case strings.Contains(t, "playready"):
		return "playready"
	default:
		return strings.TrimSpace(t)
	}
}

// IsHTTPLicense key 是否为在线 license URL。
func (d *Drm) IsHTTPLicense() bool {
	if d == nil {
		return false
	}
	k := strings.TrimSpace(d.Key)
	return strings.HasPrefix(k, "http://") || strings.HasPrefix(k, "https://")
}

// DesktopSupported 桌面端目前无法完整播放任何 DRM（保留 API 供后续扩展）。
func (d *Drm) DesktopSupported() bool {
	return false
}

// DesktopError 返回桌面端播放前的明确错误；无 DRM 返回 nil。
func (d *Drm) DesktopError() error {
	if d == nil || strings.TrimSpace(d.Type) == "" {
		return nil
	}
	switch d.Scheme() {
	case "widevine":
		return fmt.Errorf("桌面端不支持 Widevine DRM（需 Android/浏览器 CDM）")
	case "playready":
		return fmt.Errorf("桌面端不支持 PlayReady DRM")
	case "clearkey":
		if d.IsHTTPLicense() {
			return fmt.Errorf("桌面端暂不支持 ClearKey 在线 license")
		}
		return fmt.Errorf("ClearKey 已识别，但桌面播放器暂无法解密（可用 TV/手机端）")
	default:
		return fmt.Errorf("桌面端不支持 DRM：%s", d.Type)
	}
}

// NormalizeClearKey 将 kid:key 或已有 JSON 规范为 ClearKey JWK JSON。
func NormalizeClearKey(raw string) string {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return ""
	}
	raw = strings.ReplaceAll(raw, "\"", "")
	// 已是 JSON
	if strings.HasPrefix(raw, "{") {
		var probe struct {
			Keys []json.RawMessage `json:"keys"`
		}
		if err := json.Unmarshal([]byte(raw), &probe); err == nil && len(probe.Keys) > 0 {
			return raw
		}
	}
	cleaned := strings.ReplaceAll(strings.ReplaceAll(raw, "{", ""), "}", "")
	type keyEntry struct {
		Kty string `json:"kty"`
		Kid string `json:"kid"`
		K   string `json:"k"`
	}
	out := struct {
		Keys []keyEntry `json:"keys"`
		Type string     `json:"type"`
	}{Type: "temporary"}
	for _, part := range strings.Split(cleaned, ",") {
		part = strings.TrimSpace(part)
		if part == "" {
			continue
		}
		kv := strings.SplitN(part, ":", 2)
		if len(kv) != 2 {
			continue
		}
		kidHex := strings.TrimSpace(kv[0])
		kHex := strings.TrimSpace(kv[1])
		kidB, err1 := hex.DecodeString(kidHex)
		kB, err2 := hex.DecodeString(kHex)
		if err1 != nil || err2 != nil || len(kidB) == 0 || len(kB) == 0 {
			continue
		}
		out.Keys = append(out.Keys, keyEntry{
			Kty: "oct",
			Kid: strings.TrimRight(base64.RawURLEncoding.EncodeToString(kidB), "="),
			K:   strings.TrimRight(base64.RawURLEncoding.EncodeToString(kB), "="),
		})
	}
	if len(out.Keys) == 0 {
		return raw
	}
	b, err := json.Marshal(out)
	if err != nil {
		return raw
	}
	return string(b)
}
