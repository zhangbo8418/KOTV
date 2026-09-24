package util

import (
	"crypto/md5"
	"crypto/tls"
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
	"sync"
	"time"
)

var client = &http.Client{Timeout: 30 * time.Second}

// insecureClient：爬虫/CMS/jar 下载用不校验证书（OkHttp trust-all）；鉴权/更新仍走 client。
var insecureClient = newInsecureClient(nil)

// insecureRedirectMap ResponseInterceptor.redirectMap（CMS insecure）。
var insecureRedirectMap sync.Map

func rememberInsecureRedirect(from, location string) {
	from = strings.TrimSpace(from)
	location = strings.TrimSpace(location)
	if from == "" || location == "" {
		return
	}
	abs := location
	if !strings.HasPrefix(location, "http://") && !strings.HasPrefix(location, "https://") {
		if bu, err := url.Parse(from); err == nil {
			if ref, err := url.Parse(location); err == nil {
				abs = bu.ResolveReference(ref).String()
			}
		}
	}
	insecureRedirectMap.Store(abs, from)
}

func lookupInsecureRedirectOrigin(requestURL string) (string, bool) {
	if v, ok := insecureRedirectMap.Load(strings.TrimSpace(requestURL)); ok {
		if s, ok := v.(string); ok && s != "" {
			return s, true
		}
	}
	return "", false
}

func trackInsecureRedirects(req *http.Request, via []*http.Request) error {
	if len(via) >= 10 {
		return http.ErrUseLastResponse
	}
	if len(via) > 0 && req != nil && req.URL != nil {
		prev := via[len(via)-1]
		if prev != nil && prev.URL != nil {
			rememberInsecureRedirect(prev.URL.String(), req.URL.String())
		}
	}
	return nil
}

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
		req.Header.Set("User-Agent", "okhttp/4.12.0")
	}
	for k, v := range headers {
		req.Header.Set(k, v)
	}
}

// VodNet hooks：spider 注册，给 CMS insecure / 其它入口注入配置 headers·hosts。
var (
	vodRewriteHost func(string) string
	vodInjectHdrs  func(string, map[string]string) map[string]string
)

// SetVodNetHooks 由 spider 在 init 注册，避免 util↔spider 循环依赖。
func SetVodNetHooks(rewriteHost func(string) string, injectHeaders func(string, map[string]string) map[string]string) {
	vodRewriteHost = rewriteHost
	vodInjectHdrs = injectHeaders
}

func applyVodNet(rawURL string, headers map[string]string) (string, map[string]string) {
	// 先按原始 host 注入头，再改写 URL host（OkDns 只影响解析，URL host 在拦截器侧仍是原名）。
	if vodInjectHdrs != nil {
		headers = vodInjectHdrs(rawURL, headers)
	}
	if vodRewriteHost != nil {
		rawURL = vodRewriteHost(rawURL)
	}
	return rawURL, headers
}

func doRequest(req *http.Request) ([]byte, error) {
	return doRequestWith(client, req)
}

func doRequestWith(c *http.Client, req *http.Request) ([]byte, error) {
	return doRequestCore(c, req, false)
}

// doRequestAllowError 读完 body 后不因 HTTP ≥400 失败（CMS OkHttp.string 行为）。
func doRequestAllowError(c *http.Client, req *http.Request) ([]byte, error) {
	return doRequestCore(c, req, true)
}

func doRequestCore(c *http.Client, req *http.Request, allowErrorStatus bool) ([]byte, error) {
	if c == nil {
		c = client
	}
	if allowErrorStatus {
		ApplyBasicFromUserInfo(req)
	}
	resp, err := c.Do(req)
	if err != nil {
		return nil, err
	}
	if allowErrorStatus && resp.StatusCode == http.StatusUnauthorized {
		if retry, rerr := RetryAuthOn401(c, req, resp); rerr == nil && retry != nil {
			resp = retry
		}
	}
	defer resp.Body.Close()
	raw, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, err
	}
	enc := resp.Header.Get("Content-Encoding")
	b := DecodeContentEncoding(enc, raw)
	if allowErrorStatus {
		if isHTTPRedirectStatus(resp.StatusCode) {
			if loc := resp.Header.Get("Location"); loc != "" && req.URL != nil {
				rememberInsecureRedirect(req.URL.String(), loc)
			}
		}
		if resp.StatusCode == http.StatusNotAcceptable && req.URL != nil {
			if origin, ok := lookupInsecureRedirectOrigin(req.URL.String()); ok {
				req2, err2 := http.NewRequest(http.MethodGet, origin, nil)
				if err2 == nil {
					for k, vv := range req.Header {
						for _, v := range vv {
							req2.Header.Add(k, v)
						}
					}
					return doRequestCore(c, req2, true)
				}
			}
		}
	}
	if !allowErrorStatus && resp.StatusCode >= 400 {
		return nil, &HTTPError{Code: resp.StatusCode, Body: string(b)}
	}
	return b, nil
}

func isHTTPRedirectStatus(code int) bool {
	switch code {
	case 301, 302, 303, 307, 308:
		return true
	default:
		return false
	}
}

// GetClient 返回可配置代理的 HTTP 客户端。
func GetClient() *http.Client {
	return client
}

// InsecureClient 爬虫/CMS/jar 下载用客户端（跳过 TLS 校验，复用代理）。
func InsecureClient() *http.Client {
	return insecureClient
}

func newInsecureClient(proxy func(*http.Request) (*url.URL, error)) *http.Client {
	transport := &http.Transport{}
	if t, ok := http.DefaultTransport.(*http.Transport); ok {
		transport = t.Clone()
	}
	transport.TLSClientConfig = &tls.Config{InsecureSkipVerify: true} //nolint:gosec
	transport.Proxy = proxy
	return &http.Client{
		Timeout:       30 * time.Second,
		Transport:     transport,
		CheckRedirect: trackInsecureRedirects,
	}
}

// HTTPGetInsecure 同 HTTPGet，但不校验证书。
func HTTPGetInsecure(rawURL string, headers map[string]string) (string, error) {
	b, err := HTTPGetBytesInsecure(rawURL, headers)
	if err != nil {
		return "", err
	}
	return string(b), nil
}

// HTTPGetBytesInsecure 同 HTTPGetBytes，但不校验证书；≥400 仍报错（jar/Py 二进制下载）。
func HTTPGetBytesInsecure(rawURL string, headers map[string]string) ([]byte, error) {
	return httpGetParamsBytesInsecure(rawURL, headers, nil, false)
}

// HTTPGetParamsInsecure 同 HTTPGetParams，但不校验证书；读 body 不看 status（CMS）。
func HTTPGetParamsInsecure(rawURL string, headers map[string]string, params map[string]string) (string, error) {
	b, err := HTTPGetParamsBytesInsecure(rawURL, headers, params)
	if err != nil {
		return "", err
	}
	return string(b), nil
}

// HTTPGetParamsBytesInsecure 同 HTTPGetParamsBytes，但不校验证书；读 body 不看 status（CMS）。
func HTTPGetParamsBytesInsecure(rawURL string, headers map[string]string, params map[string]string) ([]byte, error) {
	return httpGetParamsBytesInsecure(rawURL, headers, params, true)
}

func httpGetParamsBytesInsecure(rawURL string, headers map[string]string, params map[string]string, allowErrorStatus bool) ([]byte, error) {
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
		u.RawQuery = EncodeQueryOkHTTP(q)
		rawURL = u.String()
	}
	rawURL = ApplyStickyAuthQuery(rawURL)
	rawURL, headers = applyVodNet(rawURL, headers)
	req, err := http.NewRequest(http.MethodGet, rawURL, nil)
	if err != nil {
		return nil, err
	}
	applyHeaders(req, headers)
	if allowErrorStatus {
		return doRequestAllowError(insecureClient, req)
	}
	return doRequestWith(insecureClient, req)
}

// HTTPPostFormInsecure 同 HTTPPostForm，但不校验证书；读 body 不看 status（CMS）。
func HTTPPostFormInsecure(rawURL string, headers map[string]string, params map[string]string) (string, error) {
	rawURL = EncodeURL(rawURL)
	rawURL = ApplyStickyAuthQuery(rawURL)
	rawURL, headers = applyVodNet(rawURL, headers)
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
	b, err := doRequestAllowError(insecureClient, req)
	if err != nil {
		return "", err
	}
	return string(b), nil
}

// SetProxy 设置 HTTP 代理，空则清除。格式 http://host:port 或 host:port。
func SetProxy(proxyURL string) {
	proxyURL = strings.TrimSpace(proxyURL)
	transport := &http.Transport{}
	if t, ok := http.DefaultTransport.(*http.Transport); ok {
		transport = t.Clone()
	}
	var proxy func(*http.Request) (*url.URL, error)
	if proxyURL == "" || proxyURL == "false" || strings.HasPrefix(proxyURL, "false#") {
		proxy = nil
	} else {
		if i := strings.Index(proxyURL, "#"); i >= 0 {
			proxyURL = proxyURL[i+1:]
		}
		if proxyURL != "" {
			if !strings.Contains(proxyURL, "://") {
				proxyURL = "http://" + proxyURL
			}
			if u, err := url.Parse(proxyURL); err == nil {
				// ProxyURL 会代理 127.0.0.1；本机 allinone/10079/引擎端口必须直连。
				fixed := http.ProxyURL(u)
				proxy = func(req *http.Request) (*url.URL, error) {
					if req != nil && req.URL != nil {
						h := strings.ToLower(req.URL.Hostname())
						if h == "127.0.0.1" || h == "localhost" || h == "::1" {
							return nil, nil
						}
					}
					return fixed(req)
				}
			}
		}
	}
	transport.Proxy = proxy
	client = &http.Client{Timeout: 30 * time.Second, Transport: transport}
	insecureClient = newInsecureClient(proxy)
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
