package util

import (
	"crypto/md5"
	"encoding/hex"
	"encoding/json"
	"io"
	"net/http"
	"net/url"
	"os"
	"path"
	"path/filepath"
	"runtime"
	"strings"
	"time"
)

var client = &http.Client{Timeout: 30 * time.Second}

// FileURLPath 将 file:// / file: URL 解析为本地路径；非 file URL 返回 false。
func FileURLPath(raw string) (string, bool) {
	raw = strings.TrimSpace(raw)
	if !strings.HasPrefix(strings.ToLower(raw), "file:") {
		return "", false
	}
	u, err := url.Parse(raw)
	if err != nil {
		return "", false
	}
	name := u.Path
	if name == "" {
		name = u.Opaque
	}
	name, err = url.PathUnescape(name)
	if err != nil || name == "" {
		return "", false
	}
	// Windows: file:///C:/foo → Path=/C:/foo
	if runtime.GOOS == "windows" && len(name) >= 3 && name[0] == '/' && name[2] == ':' {
		name = name[1:]
	}
	return filepath.FromSlash(name), true
}

// EncodeURL 对含非 ASCII 的 URL 做 path/query 编码。
func EncodeURL(raw string) string {
	raw = strings.TrimSpace(raw)
	u, err := url.Parse(raw)
	if err != nil {
		return raw
	}
	// Path 可能含中文/emoji，EscapedPath 更稳妥
	if u.RawPath == "" && u.Path != "" {
		u.RawPath = u.EscapedPath()
	}
	if u.RawQuery != "" {
		if q, err := url.ParseQuery(u.RawQuery); err == nil {
			u.RawQuery = q.Encode()
		}
	}
	return u.String()
}

// HTTPGet 下载文本内容。
func HTTPGet(rawURL string, headers map[string]string) (string, error) {
	b, err := HTTPGetBytes(rawURL, headers)
	if err != nil {
		return "", err
	}
	return string(b), nil
}

// HTTPGetBytes 下载字节内容。
func HTTPGetBytes(rawURL string, headers map[string]string) ([]byte, error) {
	return HTTPGetParamsBytes(rawURL, headers, nil)
}

// HTTPGetParams 带 query 参数的 GET，带 query 的 GET。
func HTTPGetParams(rawURL string, headers map[string]string, params map[string]string) (string, error) {
	b, err := HTTPGetParamsBytes(rawURL, headers, params)
	if err != nil {
		return "", err
	}
	return string(b), nil
}

// HTTPGetParamsBytes 带 query 参数的 GET，返回字节。
func HTTPGetParamsBytes(rawURL string, headers map[string]string, params map[string]string) ([]byte, error) {
	rawURL = strings.TrimSpace(rawURL)
	if local, ok := FileURLPath(rawURL); ok {
		return os.ReadFile(local)
	}
	rawURL = EncodeURL(rawURL)
	if len(params) > 0 {
		u, err := url.Parse(rawURL)
		if err != nil {
			return nil, err
		}
		q := u.Query()
		for k, v := range params {
			q.Set(k, v)
		}
		u.RawQuery = q.Encode()
		rawURL = u.String()
	}
	req, err := http.NewRequest(http.MethodGet, rawURL, nil)
	if err != nil {
		return nil, err
	}
	applyHeaders(req, headers)
	return doRequest(req)
}

// HTTPPostForm 以 application/x-www-form-urlencoded 提交，form body。
func HTTPPostForm(rawURL string, headers map[string]string, params map[string]string) (string, error) {
	rawURL = EncodeURL(rawURL)
	form := url.Values{}
	for k, v := range params {
		form.Set(k, v)
	}
	req, err := http.NewRequest(http.MethodPost, rawURL, strings.NewReader(form.Encode()))
	if err != nil {
		return "", err
	}
	applyHeaders(req, headers)
	if req.Header.Get("Content-Type") == "" {
		req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	}
	b, err := doRequest(req)
	if err != nil {
		return "", err
	}
	return string(b), nil
}

func applyHeaders(req *http.Request, headers map[string]string) {
	if headers == nil || headers["User-Agent"] == "" {
		req.Header.Set("User-Agent", "Mozilla/5.0 KOTV/1.0")
	}
	for k, v := range headers {
		req.Header.Set(k, v)
	}
}

func doRequest(req *http.Request) ([]byte, error) {
	resp, err := GetClient().Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	b, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, err
	}
	if resp.StatusCode >= 400 {
		return nil, &HTTPError{Code: resp.StatusCode, Body: string(b)}
	}
	return b, nil
}

// GetClient 返回可配置代理的 HTTP 客户端。
func GetClient() *http.Client {
	return client
}

// SetProxy 设置 HTTP 代理，空则清除。格式 http://host:port 或 host:port。
func SetProxy(proxyURL string) {
	proxyURL = strings.TrimSpace(proxyURL)
	transport := &http.Transport{}
	if t, ok := http.DefaultTransport.(*http.Transport); ok {
		transport = t.Clone()
	}
	if proxyURL == "" || proxyURL == "false" || strings.HasPrefix(proxyURL, "false#") {
		transport.Proxy = nil
		client = &http.Client{Timeout: 30 * time.Second, Transport: transport}
		return
	}
	if i := strings.Index(proxyURL, "#"); i >= 0 {
		proxyURL = proxyURL[i+1:]
	}
	if proxyURL == "" {
		client = &http.Client{Timeout: 30 * time.Second, Transport: transport}
		return
	}
	if !strings.Contains(proxyURL, "://") {
		proxyURL = "http://" + proxyURL
	}
	u, err := url.Parse(proxyURL)
	if err != nil {
		return
	}
	transport.Proxy = http.ProxyURL(u)
	client = &http.Client{Timeout: 30 * time.Second, Transport: transport}
}

type HTTPError struct {
	Code int
	Body string
}

func (e *HTTPError) Error() string {
	return http.StatusText(e.Code)
}

// MD5 计算字符串 MD5。
func MD5(s string) string {
	h := md5.Sum([]byte(s))
	return hex.EncodeToString(h[:])
}

// CleanJSONComments 移除 JSON 外的 // 与 /* */ 注释，不破坏字符串内的 https://。
func CleanJSONComments(data string) string {
	var b strings.Builder
	b.Grow(len(data))
	inStr := false
	esc := false
	i := 0
	for i < len(data) {
		c := data[i]
		if inStr {
			b.WriteByte(c)
			if esc {
				esc = false
			} else if c == '\\' {
				esc = true
			} else if c == '"' {
				inStr = false
			}
			i++
			continue
		}
		if c == '"' {
			inStr = true
			b.WriteByte(c)
			i++
			continue
		}
		// line comment
		if c == '/' && i+1 < len(data) && data[i+1] == '/' {
			for i < len(data) && data[i] != '\n' {
				i++
			}
			continue
		}
		// block comment
		if c == '/' && i+1 < len(data) && data[i+1] == '*' {
			i += 2
			for i+1 < len(data) && !(data[i] == '*' && data[i+1] == '/') {
				i++
			}
			if i+1 < len(data) {
				i += 2
			}
			continue
		}
		b.WriteByte(c)
		i++
	}
	return b.String()
}

// DecodeJSON 反序列化 JSON。
func DecodeJSON[T any](data string) (T, error) {
	var v T
	err := json.Unmarshal([]byte(data), &v)
	return v, err
}

// EncodeJSON 序列化为 JSON。
func EncodeJSON(v interface{}) string {
	b, _ := json.Marshal(v)
	return string(b)
}

// ResolveRelativeURL 解析相对路径。
// http(s) 配置目录无尾部 / 时，仍把最后一段当目录拼相对资源。
func ResolveRelativeURL(base, rel string) string {
	rel = strings.TrimSpace(rel)
	if rel == "" {
		return ""
	}
	if strings.HasPrefix(rel, "http://") || strings.HasPrefix(rel, "https://") || strings.HasPrefix(rel, "file://") {
		return rel
	}
	base = strings.TrimSpace(base)
	if base == "" {
		return rel
	}
	base = ensureURLDirBase(base)
	bu, err := url.Parse(EncodeURL(base))
	if err != nil {
		return ResolveRelativeURLLegacy(base, rel)
	}
	ref, err := url.Parse(rel)
	if err != nil {
		return ResolveRelativeURLLegacy(base, rel)
	}
	return bu.ResolveReference(ref).String()
}

// ensureURLDirBase 若 base 像「配置目录」而无尾 /，补上，避免 ResolveReference 吃掉最后一段。
func ensureURLDirBase(base string) string {
	if !strings.HasPrefix(base, "http://") && !strings.HasPrefix(base, "https://") && !strings.HasPrefix(base, "file://") {
		return base
	}
	if strings.HasSuffix(base, "/") {
		return base
	}
	// 已有明显文件后缀则保持（…/config.json）
	u, err := url.Parse(EncodeURL(base))
	if err != nil {
		return base + "/"
	}
	seg := path.Base(u.Path)
	if strings.Contains(seg, ".") && !strings.HasPrefix(seg, ".") {
		// config.json / api.json 等：用其所在目录
		return base
	}
	return base + "/"
}

// ResolveRelativeURLLegacy 旧逻辑回落。
func ResolveRelativeURLLegacy(base, rel string) string {
	if strings.HasPrefix(rel, "/") {
		idx := strings.Index(base[8:], "/")
		if idx < 0 {
			return strings.TrimRight(base, "/") + rel
		}
		origin := base[:8+idx]
		return origin + rel
	}
	last := strings.LastIndex(base, "/")
	if last < 0 {
		return rel
	}
	return base[:last+1] + rel
}

// SplitJarSpec 解析 spider.jar;md5;hash → (path, md5)。
func SplitJarSpec(spec string) (path, md5 string) {
	spec = strings.TrimSpace(spec)
	const sep = ";md5;"
	if i := strings.Index(strings.ToLower(spec), sep); i >= 0 {
		return strings.TrimSpace(spec[:i]), strings.TrimSpace(spec[i+len(sep):])
	}
	// 兼容 spider.jar;md5;HASH 大小写
	if i := strings.Index(spec, ";"); i >= 0 {
		parts := strings.Split(spec, ";")
		if len(parts) >= 3 && strings.EqualFold(parts[1], "md5") {
			return strings.TrimSpace(parts[0]), strings.TrimSpace(parts[2])
		}
	}
	return spec, ""
}

// ResolveJarURL 将配置中的 spider 字段解析为可下载 URL。
func ResolveJarURL(configURL, spiderSpec string) string {
	path, _ := SplitJarSpec(spiderSpec)
	if path == "" {
		return ""
	}
	if strings.HasPrefix(path, "http://") || strings.HasPrefix(path, "https://") || strings.HasPrefix(strings.ToLower(path), "file:") {
		return path
	}
	return ResolveRelativeURL(configURL, path)
}
