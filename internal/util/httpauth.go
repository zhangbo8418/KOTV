package util

import (
	"crypto/md5"
	"crypto/rand"
	"encoding/base64"
	"encoding/hex"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"regexp"
	"strings"
	"sync"
)

// RequestInterceptor.checkAuth + AuthInterceptor 的 Go 侧表（JS _http / CMS insecure 共用）。
var (
	httpAuthMu     sync.RWMutex
	authQueryByHost = map[string]string{}
	authUserByHost  = map[string]string{}
)

var digestParamRe = regexp.MustCompile(`(\w+)=(?:"([^"]*)"|([^,\s"]+))`)

// ClearHTTPAuth 换源/重载配置时清空粘性 auth。
func ClearHTTPAuth() {
	httpAuthMu.Lock()
	authQueryByHost = map[string]string{}
	authUserByHost = map[string]string{}
	httpAuthMu.Unlock()
}

// ApplyStickyAuthQuery RequestInterceptor：有 ?auth= 则记；无则按 host 回填。
func ApplyStickyAuthQuery(rawURL string) string {
	rawURL = strings.TrimSpace(rawURL)
	if rawURL == "" {
		return rawURL
	}
	u, err := url.Parse(rawURL)
	if err != nil || u.Host == "" {
		return rawURL
	}
	host := u.Hostname()
	q := u.Query()
	if auth := strings.TrimSpace(q.Get("auth")); auth != "" {
		httpAuthMu.Lock()
		authQueryByHost[host] = auth
		httpAuthMu.Unlock()
		return rawURL
	}
	httpAuthMu.RLock()
	stored, ok := authQueryByHost[host]
	httpAuthMu.RUnlock()
	if !ok || stored == "" {
		return rawURL
	}
	q.Set("auth", stored)
	u.RawQuery = EncodeQueryOkHTTP(q)
	return u.String()
}

// ApplyBasicFromUserInfo AuthInterceptor.check：URL userinfo → Basic，并按 host 记忆。
func ApplyBasicFromUserInfo(req *http.Request) {
	if req == nil || req.URL == nil {
		return
	}
	user := req.URL.User
	if user == nil {
		return
	}
	userInfo := user.String()
	if userInfo == "" {
		return
	}
	host := req.URL.Hostname()
	httpAuthMu.Lock()
	authUserByHost[host] = userInfo
	httpAuthMu.Unlock()
	req.Header.Set("Authorization", BasicAuthHeader(userInfo))
}

// RetryAuthOn401 AuthInterceptor：401 时用记忆凭据发 Digest/Basic 再请求一次。
func RetryAuthOn401(client *http.Client, req *http.Request, resp *http.Response) (*http.Response, error) {
	if client == nil || req == nil || resp == nil || resp.StatusCode != http.StatusUnauthorized {
		return resp, nil
	}
	host := ""
	if req.URL != nil {
		host = req.URL.Hostname()
	}
	userInfo := ""
	if req.URL != nil && req.URL.User != nil {
		userInfo = req.URL.User.String()
	}
	if userInfo == "" {
		httpAuthMu.RLock()
		userInfo = authUserByHost[host]
		httpAuthMu.RUnlock()
	}
	if userInfo == "" {
		return resp, nil
	}
	www := resp.Header.Get("WWW-Authenticate")
	_ = resp.Body.Close()
	auth := BasicAuthHeader(userInfo)
	if strings.HasPrefix(strings.TrimSpace(www), "Digest") {
		auth = DigestAuthHeader(userInfo, www, req)
	}
	retry := req.Clone(req.Context())
	retry.Header.Set("Authorization", auth)
	if req.GetBody != nil {
		body, err := req.GetBody()
		if err == nil {
			retry.Body = body
		}
	}
	return client.Do(retry)
}

// BasicAuthHeader Auth.basic。
func BasicAuthHeader(userInfo string) string {
	if !strings.Contains(userInfo, ":") {
		userInfo += ":"
	}
	return "Basic " + base64.StdEncoding.EncodeToString([]byte(userInfo))
}

// DigestAuthHeader Auth.digest。
func DigestAuthHeader(userInfo, wwwAuthenticate string, req *http.Request) string {
	header := strings.TrimSpace(wwwAuthenticate)
	if len(header) >= 7 && strings.EqualFold(header[:7], "Digest ") {
		header = header[7:]
	} else if strings.HasPrefix(strings.ToLower(header), "digest") {
		if i := strings.Index(header, " "); i >= 0 {
			header = header[i+1:]
		}
	}
	params := parseDigestParams(header)
	parts := strings.SplitN(userInfo, ":", 2)
	username := parts[0]
	password := ""
	if len(parts) > 1 {
		password = parts[1]
	}
	realm := params["realm"]
	nonce := params["nonce"]
	opaque := params["opaque"]
	uri := digestURI(req)
	qop := selectQop(params["qop"])
	nc := "00000001"
	cnonce := newCnonce()
	ha1 := md5Hex(username + ":" + realm + ":" + password)
	method := http.MethodGet
	if req != nil && req.Method != "" {
		method = req.Method
	}
	ha2 := md5Hex(method + ":" + uri)
	var response string
	if qop == "" {
		response = md5Hex(ha1 + ":" + nonce + ":" + ha2)
	} else {
		response = md5Hex(ha1 + ":" + nonce + ":" + nc + ":" + cnonce + ":" + qop + ":" + ha2)
	}
	fields := []string{
		fmt.Sprintf(`username="%s"`, username),
		fmt.Sprintf(`realm="%s"`, realm),
		fmt.Sprintf(`nonce="%s"`, nonce),
		fmt.Sprintf(`uri="%s"`, uri),
	}
	if qop != "" {
		fields = append(fields, fmt.Sprintf(`cnonce="%s"`, cnonce), "nc="+nc, "qop="+qop)
	}
	fields = append(fields, fmt.Sprintf(`response="%s"`, response))
	if opaque != "" {
		fields = append(fields, fmt.Sprintf(`opaque="%s"`, opaque))
	}
	return "Digest " + strings.Join(fields, ", ")
}

func digestURI(req *http.Request) string {
	if req == nil || req.URL == nil {
		return "/"
	}
	path := req.URL.EscapedPath()
	if path == "" {
		path = "/"
	}
	if req.URL.RawQuery != "" {
		return path + "?" + req.URL.RawQuery
	}
	return path
}

func selectQop(qop string) string {
	if qop == "" {
		return ""
	}
	for _, opt := range strings.Split(qop, ",") {
		if strings.EqualFold(strings.TrimSpace(opt), "auth") {
			return "auth"
		}
	}
	return ""
}

func parseDigestParams(header string) map[string]string {
	out := map[string]string{}
	for _, m := range digestParamRe.FindAllStringSubmatch(header, -1) {
		key := m[1]
		val := m[2]
		if val == "" {
			val = m[3]
		}
		out[key] = strings.TrimSpace(val)
	}
	return out
}

func md5Hex(s string) string {
	sum := md5.Sum([]byte(s))
	return hex.EncodeToString(sum[:])
}

func newCnonce() string {
	b := make([]byte, 16)
	_, _ = rand.Read(b)
	return hex.EncodeToString(b)
}

// EncodeQueryOkHTTP 空格编为 %20（HttpUrl.addQueryParameter），而非 application/x-www-form-urlencoded 的 +。
func EncodeQueryOkHTTP(q url.Values) string {
	if len(q) == 0 {
		return ""
	}
	return strings.ReplaceAll(q.Encode(), "+", "%20")
}

// DrainAndDecodeBody 读完 body，按 Content-Encoding 做 gzip/raw deflate 解码。
func DrainAndDecodeBody(resp *http.Response) []byte {
	if resp == nil || resp.Body == nil {
		return nil
	}
	b, _ := io.ReadAll(resp.Body)
	return DecodeContentEncoding(resp.Header.Get("Content-Encoding"), b)
}
