package config

import (
	"crypto/aes"
	"crypto/cipher"
	"encoding/base64"
	"encoding/hex"
	"fmt"
	"regexp"
	"strings"

	"github.com/bobo/KOTV/internal/util"
)

var (
	// 8 位字母数字 + `**`，其后为 base64 正文。
	starMarkerRe = regexp.MustCompile(`[A-Za-z0-9]{8}\*\*`)
	wsRe         = regexp.MustCompile(`\s+`)
	// Decoder.JS_URI：配置串里的相对 .js? 查询，展开时先保护 ./ ../。
	jsURIRe = regexp.MustCompile(`"(\.|\\.\\.)/(.?|.+?)\\.js\\?(.?|.+?)"`)
)

// DecodeConfigBody 解开两种包装过的配置正文；已是 JSON 对象/数组的原样返回。
//
//   - 正文含 `xxxxxxxx**`：取标记后的内容做标准 base64 解码。
//   - 正文以 `2423` 开头：hex 串；解码后 `$#…#$` 之间为 AES key、末 13 字符为 IV（右补 0 到 16），
//     `2324` 之后到倒数 26 个字符为密文，AES/CBC/PKCS5 解密。
func DecodeConfigBody(data string) (string, error) {
	trimmed := strings.TrimSpace(data)
	if trimmed == "" {
		return "", fmt.Errorf("配置数据为空")
	}
	if strings.HasPrefix(trimmed, "{") || strings.HasPrefix(trimmed, "[") {
		return data, nil
	}
	if strings.Contains(trimmed, "**") {
		if out, ok := decodeStarBase64(trimmed); ok {
			return out, nil
		}
	}
	if strings.HasPrefix(trimmed, "2423") {
		out, err := decodeCBCHex(wsRe.ReplaceAllString(trimmed, ""))
		if err != nil {
			return "", err
		}
		return out, nil
	}
	return data, nil
}

// FixRelativePaths 按配置基址展开正文中的 `./` / `../`（Decoder.fix）。
// 先保护 `"…/*.js?…"` 串内的相对路径，展开后再还原。
func FixRelativePaths(baseURL, data string) string {
	baseURL = strings.TrimSpace(baseURL)
	if baseURL == "" || data == "" {
		return data
	}
	for {
		loc := jsURIRe.FindStringIndex(data)
		if loc == nil {
			break
		}
		ext := data[loc[0]:loc[1]]
		data = data[:loc[0]] + protectJSRelative(baseURL, ext) + data[loc[1]:]
	}
	if strings.Contains(data, "../") {
		data = strings.ReplaceAll(data, "../", util.UriResolve(baseURL, "../"))
	}
	if strings.Contains(data, "./") {
		data = strings.ReplaceAll(data, "./", util.UriResolve(baseURL, "./"))
	}
	if strings.Contains(data, "__JS1__") {
		data = strings.ReplaceAll(data, "__JS1__", "./")
	}
	if strings.Contains(data, "__JS2__") {
		data = strings.ReplaceAll(data, "__JS2__", "../")
	}
	return data
}

func protectJSRelative(baseURL, ext string) string {
	t := strings.ReplaceAll(ext, `"./"`, `"`+util.UriResolve(baseURL, "./"))
	t = strings.ReplaceAll(t, `"../`, `"`+util.UriResolve(baseURL, "../"))
	t = strings.ReplaceAll(t, "./", "__JS1__")
	t = strings.ReplaceAll(t, "../", "__JS2__")
	return t
}

func decodeStarBase64(data string) (string, bool) {
	loc := starMarkerRe.FindStringIndex(data)
	if loc == nil {
		return "", false
	}
	payload := strings.TrimSpace(data[loc[1]:])
	if payload == "" {
		return "", false
	}
	b, err := base64.StdEncoding.DecodeString(payload)
	if err != nil {
		// 缺 padding 的写法也放行。
		b, err = base64.RawStdEncoding.DecodeString(strings.TrimRight(payload, "="))
		if err != nil {
			return "", false
		}
	}
	return string(b), true
}

func decodeCBCHex(data string) (string, error) {
	raw, err := hex.DecodeString(data)
	if err != nil {
		return "", fmt.Errorf("配置解密失败: %w", err)
	}
	decoded := strings.ToLower(string(raw))
	ks := strings.Index(decoded, "$#")
	ke := strings.Index(decoded, "#$")
	if ks < 0 || ke < 0 || ke < ks+2 || len(decoded) < 13 {
		return "", fmt.Errorf("配置解密失败: 缺少 key/iv 标记")
	}
	key := padEnd16(decoded[ks+2 : ke])
	iv := padEnd16(decoded[len(decoded)-13:])
	body := data
	bs := strings.Index(body, "2324")
	if bs < 0 || len(body)-26 <= bs+4 {
		return "", fmt.Errorf("配置解密失败: 缺少密文标记")
	}
	body = body[bs+4 : len(body)-26]
	ct, err := hex.DecodeString(body)
	if err != nil {
		return "", fmt.Errorf("配置解密失败: %w", err)
	}
	pt, err := aesCBCDecryptPKCS5(ct, []byte(key), []byte(iv))
	if err != nil {
		return "", fmt.Errorf("配置解密失败: %w", err)
	}
	return string(pt), nil
}

func padEnd16(s string) string {
	if len(s) >= 16 {
		return s[:16]
	}
	return s + strings.Repeat("0", 16-len(s))
}

func aesCBCDecryptPKCS5(ct, key, iv []byte) ([]byte, error) {
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, err
	}
	if len(ct) == 0 || len(ct)%block.BlockSize() != 0 {
		return nil, fmt.Errorf("密文长度非法")
	}
	out := make([]byte, len(ct))
	cipher.NewCBCDecrypter(block, iv).CryptBlocks(out, ct)
	n := int(out[len(out)-1])
	if n <= 0 || n > block.BlockSize() || n > len(out) {
		return nil, fmt.Errorf("填充非法")
	}
	for _, b := range out[len(out)-n:] {
		if int(b) != n {
			return nil, fmt.Errorf("填充非法")
		}
	}
	return out[:len(out)-n], nil
}

// ConfigErrorMessage 配置顶层对象带非空 `msg` 时返回该文本（服务端错误说明），否则空串。
func ConfigErrorMessage(cleaned string) string {
	trimmed := strings.TrimSpace(cleaned)
	if !strings.HasPrefix(trimmed, "{") {
		return ""
	}
	type head struct {
		Msg string `json:"msg"`
	}
	h, err := util.DecodeJSON[head](trimmed)
	if err != nil {
		return ""
	}
	return strings.TrimSpace(h.Msg)
}
