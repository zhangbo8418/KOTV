package spider

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"strings"
)

// parseCatvodProxy 解析 CatVod 风格 proxy 返回值：
// [status, contentType, body, headers?, base64Flag?]
// 空/畸形 payload → error（勿伪装成 200）。
func parseCatvodProxy(raw string) (status int, contentType string, body []byte, headers map[string]string, err error) {
	raw = strings.TrimSpace(raw)
	if raw == "" || raw == "null" || raw == "[]" || raw == "{}" {
		return 0, "", nil, nil, fmt.Errorf("invalid proxy response")
	}

	var arr []json.RawMessage
	if err := json.Unmarshal([]byte(raw), &arr); err != nil || len(arr) < 3 {
		// CatVod proxy2 返回 Res 对象：{code,content,buffer,headers}。
		var res struct {
			Code    *int              `json:"code"`
			Content string            `json:"content"`
			Buffer  int               `json:"buffer"`
			Headers map[string]string `json:"headers"`
		}
		if json.Unmarshal([]byte(raw), &res) == nil && (res.Code != nil || res.Content != "" || res.Headers != nil) {
			status, contentType, body = 200, "application/octet-stream", []byte(res.Content)
			if res.Code != nil {
				status = *res.Code
			}
			if res.Headers != nil {
				if value := res.Headers["Content-Type"]; value != "" {
					contentType = value
				} else if value := res.Headers["content-type"]; value != "" {
					contentType = value
				}
			}
			if res.Buffer == 2 {
				text := res.Content
				if i := strings.Index(text, "base64,"); i >= 0 {
					text = text[i+len("base64,"):]
				}
				if decoded, decErr := base64.StdEncoding.DecodeString(text); decErr == nil {
					body = decoded
				}
			}
			// Res 对象路径：headers 只用于挑选 Content-Type，不写入 HTTP 响应。
			return status, contentType, body, nil, nil
		}
		return 0, "", nil, nil, fmt.Errorf("invalid proxy response")
	}

	status = 200
	_ = json.Unmarshal(arr[0], &status)
	contentType = "application/octet-stream"
	_ = json.Unmarshal(arr[1], &contentType)

	// body 可能是 string / number / object / array
	var asString string
	if err := json.Unmarshal(arr[2], &asString); err == nil {
		body = []byte(asString)
	} else {
		body = []byte(arr[2])
	}

	if len(arr) > 3 && string(arr[3]) != "null" {
		headers = map[string]string{}
		_ = json.Unmarshal(arr[3], &headers)
		// 有些实现返回 JSON 字符串
		if len(headers) == 0 {
			var headerJSON string
			if json.Unmarshal(arr[3], &headerJSON) == nil && headerJSON != "" {
				_ = json.Unmarshal([]byte(headerJSON), &headers)
			}
		}
	}

	base64Flag := 0
	if len(arr) > 4 {
		_ = json.Unmarshal(arr[4], &base64Flag)
	}
	if base64Flag == 1 {
		text := string(body)
		if i := strings.Index(text, "base64,"); i >= 0 {
			text = text[i+len("base64,"):]
		}
		if decoded, decErr := base64.StdEncoding.DecodeString(text); decErr == nil {
			body = decoded
		}
	}
	return status, contentType, body, headers, nil
}
