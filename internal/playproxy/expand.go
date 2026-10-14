package playproxy

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net/url"
	"strings"

	"github.com/bobo/KOTV/internal/hostclient"
	"github.com/bobo/KOTV/internal/localproxy"
)

// ShouldExpandSpiderMediaProxy 是否把网盘类 /proxy?url=&header= 展开成 CDN。
// 本机（PublicBase 空）否：播放器打 /proxy，由 jar 流式回传。
// 远端（PublicBase 非空）是：展开后 /proxy/play Range 转发。
func ShouldExpandSpiderMediaProxy() bool {
	return strings.TrimSpace(hostclient.PublicBase()) != ""
}

// ExpandSpiderMediaProxy 将网盘类「/proxy?do=*&url=&header=」展开为真实直链+请求头。
//
// jar（Quark / UC 等）常把 CDN 与 Cookie 编进本地代理查询串。本机请求应保持
// /proxy→jar（本机 TCP 泵流），勿展开。仅远端客户端才展开后走 /proxy/play。
// do=js|py 永不展开。调用前先看 ShouldExpandSpiderMediaProxy。
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
	// do=js|py 须走脚本 Proxy，不能展开成直链。
	if do := strings.ToLower(strings.TrimSpace(firstQuery(q, "do"))); do == "js" || do == "py" {
		return raw, existing, false
	}
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
