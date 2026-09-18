package model

import (
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"
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

// DesktopSupported 桌面仅支持本地 ClearKey（kid:key / JWK → lavf decryption_key）。
// HTTP license 需先 [PrepareForDesktop] 拉成本地密钥。
func (d *Drm) DesktopSupported() bool {
	if d == nil || strings.TrimSpace(d.Type) == "" {
		return false
	}
	if d.Scheme() != "clearkey" || d.IsHTTPLicense() {
		return false
	}
	return d.ClearKeyHex() != ""
}

// ClearKeyHex 取出首个密钥的 hex（供 ffmpeg/mpv demuxer-lavf-o=decryption_key=）。
// 多 key 片源目前 lavf 只吃一把，取 keys[0]。
func (d *Drm) ClearKeyHex() string {
	if d == nil {
		return ""
	}
	raw := strings.TrimSpace(d.Key)
	if raw == "" {
		return ""
	}
	if strings.HasPrefix(raw, "{") {
		var probe struct {
			Keys []struct {
				K string `json:"k"`
			} `json:"keys"`
		}
		if err := json.Unmarshal([]byte(raw), &probe); err == nil {
			for _, e := range probe.Keys {
				if h := b64URLToHex(e.K); h != "" {
					return h
				}
			}
		}
	}
	cleaned := strings.ReplaceAll(strings.ReplaceAll(strings.ReplaceAll(raw, "\"", ""), "{", ""), "}", "")
	for _, part := range strings.Split(cleaned, ",") {
		part = strings.TrimSpace(part)
		if part == "" {
			continue
		}
		kv := strings.SplitN(part, ":", 2)
		if len(kv) != 2 {
			continue
		}
		kHex := strings.TrimSpace(kv[1])
		if _, err := hex.DecodeString(kHex); err == nil && len(kHex) >= 32 {
			return strings.ToLower(kHex)
		}
	}
	// 已是 NormalizeClearKey 后的 JWK 再试一遍。
	norm := NormalizeClearKey(raw)
	if norm != raw {
		tmp := &Drm{Key: norm, Type: "clearkey"}
		return tmp.ClearKeyHex()
	}
	return ""
}

func b64URLToHex(raw string) string {
	s := strings.TrimSpace(raw)
	if s == "" {
		return ""
	}
	s = strings.ReplaceAll(strings.ReplaceAll(s, "-", "+"), "_", "/")
	for len(s)%4 != 0 {
		s += "="
	}
	b, err := base64.StdEncoding.DecodeString(s)
	if err != nil || len(b) == 0 {
		return ""
	}
	return hex.EncodeToString(b)
}

// DesktopError 返回桌面端播放前的明确错误；无 DRM 或本地 ClearKey 返回 nil。
// HTTP ClearKey 请先调用 [PrepareForDesktop]。
func (d *Drm) DesktopError() error {
	if d == nil || strings.TrimSpace(d.Type) == "" {
		return nil
	}
	if d.DesktopSupported() {
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
		return fmt.Errorf("ClearKey 密钥无效或无法解析")
	default:
		return fmt.Errorf("桌面端不支持 DRM：%s", d.Type)
	}
}

// PrepareForDesktop 桌面开播前：拉取 ClearKey HTTP license，其余类型走 DesktopError。
// 返回值可直接交给播放器；无 DRM 时返回 (nil, nil)。
func PrepareForDesktop(d *Drm) (*Drm, error) {
	if d == nil || strings.TrimSpace(d.Type) == "" {
		return nil, nil
	}
	if d.DesktopSupported() {
		return d, nil
	}
	if d.Scheme() == "clearkey" && d.IsHTTPLicense() {
		body, err := fetchClearKeyLicense(d)
		if err != nil {
			return nil, fmt.Errorf("ClearKey 在线 license 获取失败: %w", err)
		}
		resolved := &Drm{
			Type:     "clearkey",
			Key:      body,
			ForceKey: d.ForceKey,
			Header:   d.Header,
		}
		// 可能是 kid:key 明文或 JWK JSON。
		if !strings.HasPrefix(strings.TrimSpace(body), "{") {
			resolved.Key = NormalizeClearKey(body)
		}
		if resolved.ClearKeyHex() == "" {
			return nil, fmt.Errorf("ClearKey 在线 license 无可用密钥（多 key 时仅用首个）")
		}
		return resolved, nil
	}
	return nil, d.DesktopError()
}

func fetchClearKeyLicense(d *Drm) (string, error) {
	url := strings.TrimSpace(d.Key)
	req, err := http.NewRequest(http.MethodGet, url, nil)
	if err != nil {
		return "", err
	}
	for k, v := range d.Header {
		if strings.TrimSpace(k) == "" || strings.TrimSpace(v) == "" {
			continue
		}
		req.Header.Set(k, v)
	}
	if req.Header.Get("User-Agent") == "" {
		req.Header.Set("User-Agent", "KOTV")
	}
	client := &http.Client{Timeout: 12 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return "", fmt.Errorf("HTTP %d", resp.StatusCode)
	}
	b, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		return "", err
	}
	body := strings.TrimSpace(string(b))
	if body == "" {
		return "", fmt.Errorf("空响应")
	}
	return body, nil
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
