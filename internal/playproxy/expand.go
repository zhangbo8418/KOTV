package playproxy

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net/url"
	"strings"

	"github.com/bobo/KOTV/internal/localproxy"
)

// ExpandSpiderMediaProxy 将网盘类「/proxy?do=*&url=&header=」展开为真实直链+请求头。
//
// jar 的 ProxyVideo / Quark / UC 等会把 CDN 地址和 Cookie 编进本地代理查询串。
// 若播放器直接打 /proxy，Java bridge 会把整段视频溢写到磁盘再回传，远端播 2GB+
// 原画几乎必挂（invalid or unsupported media / 超时）。
// 展开后走本包 Register → /proxy/play，支持 Range 真流式转发。
//
// m3u8 不展开：仍需 jar 改写分片地址。
func ExpandSpiderMediaProxy(raw string, existing map[string]string) (mediaURL string, headers map[string]string, ok bool) {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return raw, existing, false
	}
	raw = localproxy.ConvertScheme(raw)
	if !localproxy.IsSpiderProxyURL(raw) {
		return raw, existing, false
	}
	u, err := url.Parse(raw)
	if err != nil {
		return raw, existing, false
	}
	q := u.Query()
	encURL := firstQuery(q, "url")
	if encURL == "" {
		return raw, existing, false
	}
	decodedURL, err := decodeProxyB64(encURL)
	if err != nil || strings.TrimSpace(decodedURL) == "" {
		return raw, existing, false
	}
	decodedURL = strings.TrimSpace(decodedURL)
	low := strings.ToLower(decodedURL)
	if strings.Contains(low, ".m3u8") || strings.Contains(low, "mpegurl") {
		return raw, existing, false
	}
	if !strings.HasPrefix(low, "http://") && !strings.HasPrefix(low, "https://") {
		return raw, existing, false
	}

	out := map[string]string{}
	for k, v := range existing {
		if strings.TrimSpace(k) == "" || strings.TrimSpace(v) == "" {
			continue
		}
		out[k] = v
	}
	if encHdr := firstQuery(q, "header", "headers"); encHdr != "" {
		if rawJSON, err := decodeProxyB64(encHdr); err == nil {
			var parsed map[string]string
			if json.Unmarshal([]byte(rawJSON), &parsed) == nil {
				for k, v := range parsed {
					if strings.TrimSpace(k) == "" || strings.TrimSpace(v) == "" {
						continue
					}
					out[k] = v
				}
			} else {
				// 部分 jar 用 Map 泛型序列化成非 string 值
				var anyMap map[string]any
				if json.Unmarshal([]byte(rawJSON), &anyMap) == nil {
					for k, v := range anyMap {
						if strings.TrimSpace(k) == "" || v == nil {
							continue
						}
						s := strings.TrimSpace(stringifyJSONValue(v))
						if s != "" {
							out[k] = s
						}
					}
				}
			}
		}
	}
	return decodedURL, out, true
}

func firstQuery(q url.Values, keys ...string) string {
	for _, k := range keys {
		if v := strings.TrimSpace(q.Get(k)); v != "" {
			return v
		}
	}
	return ""
}

func decodeProxyB64(s string) (string, error) {
	s = strings.TrimSpace(s)
	// query 可能被二次 encode
	if u, err := url.QueryUnescape(s); err == nil {
		s = u
	}
	encodings := []func(string) ([]byte, error){
		base64.StdEncoding.DecodeString,
		base64.RawStdEncoding.DecodeString,
		base64.URLEncoding.DecodeString,
		base64.RawURLEncoding.DecodeString,
	}
	// 补齐标准 padding
	padded := s
	if m := len(padded) % 4; m != 0 {
		padded += strings.Repeat("=", 4-m)
	}
	for _, dec := range encodings {
		if b, err := dec(padded); err == nil {
			return string(b), nil
		}
		if b, err := dec(s); err == nil {
			return string(b), nil
		}
	}
	return "", base64.CorruptInputError(0)
}

func stringifyJSONValue(v any) string {
	switch t := v.(type) {
	case string:
		return t
	default:
		return strings.TrimSpace(fmt.Sprint(t))
	}
}
