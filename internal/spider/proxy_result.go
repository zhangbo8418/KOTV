package spider

import (
	"encoding/base64"
	"encoding/json"
	"strings"
)

// parseCatvodProxy 解析 CatVod 风格 proxy 返回值：
// [status, contentType, body, headers?, base64Flag?]
func parseCatvodProxy(raw string) (status int, contentType string, body []byte, headers map[string]string, err error) {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return 200, "application/octet-stream", nil, nil, nil
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
			status, contentType, body, headers = 200, "application/octet-stream", []byte(res.Content), res.Headers
			if res.Code != nil {
				status = *res.Code
			}
			if headers != nil {
				if value := headers["Content-Type"]; value != "" {
					contentType = value
				} else if value := headers["content-type"]; value != "" {
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
			return status, contentType, body, headers, nil
		}
		// 兼容旧脚本：非数组且非 Res 对象时直接当正文。
		return 200, "application/json", []byte(raw), nil, nil
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
