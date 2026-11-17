package util

import (
	"crypto/md5"
	"crypto/rand"
	"encoding/base64"
	"encoding/hex"
	"fmt"
	"net/http"
	"net/url"
	"regexp"
	"strings"
	"sync"
)

// HTTP 粘性鉴权表（JS _http / CMS insecure 共用）：按 owner（RuntimeUserID）+ host 记住 ?auth= 与 Basic userinfo。
const httpAuthHostMax = 256

var (
	httpAuthMu      sync.RWMutex
	authQueryByOwner = map[string]map[string]string{} // owner -> host -> auth
	authUserByOwner  = map[string]map[string]string{}
	httpAuthOwnerFn  func() string
)

var digestParamRe = regexp.MustCompile(`(\w+)=(?:"([^"]*)"|([^,\s"]+))`)

// SetHTTPAuthOwner 注入租户键（通常 hostclient.RuntimeUserID）；空串=本机共享桶。
func SetHTTPAuthOwner(fn func() string) {
	httpAuthOwnerFn = fn
}

func httpAuthOwner() string {
	if httpAuthOwnerFn == nil {
		return ""
	}
	return strings.TrimSpace(httpAuthOwnerFn())
}

func authQueryMap(owner string) map[string]string {
	m := authQueryByOwner[owner]
	if m == nil {
		m = map[string]string{}
		authQueryByOwner[owner] = m
	}
	return m
}

func authUserMap(owner string) map[string]string {
	m := authUserByOwner[owner]
	if m == nil {
		m = map[string]string{}
		authUserByOwner[owner] = m
	}
	return m
}

// ClearHTTPAuth 清空当前租户桶的粘性 auth（换源）。owner 空则清本机共享桶。
func ClearHTTPAuth() {
	owner := httpAuthOwner()
	httpAuthMu.Lock()
	delete(authQueryByOwner, owner)
	delete(authUserByOwner, owner)
	httpAuthMu.Unlock()
}

// ClearAllHTTPAuth 清空全部租户桶（清缓存）。
func ClearAllHTTPAuth() {
	httpAuthMu.Lock()
	authQueryByOwner = map[string]map[string]string{}
	authUserByOwner = map[string]map[string]string{}
	httpAuthMu.Unlock()
}

// ClearHTTPAuthForUser 清指定远端用户桶。
func ClearHTTPAuthForUser(userID string) {
	userID = strings.TrimSpace(userID)
	if userID == "" {
		return
	}
	httpAuthMu.Lock()
	delete(authQueryByOwner, userID)
	delete(authUserByOwner, userID)
	httpAuthMu.Unlock()
}

// trimHTTPAuthHostsLocked 超上限时两表各删约一半（调用方已持写锁）。
func trimHTTPAuthHostsLocked(owner string) {
	trimMapHalf := func(m map[string]string) {
		if len(m) < httpAuthHostMax {
			return
		}
		n := len(m) / 2
		for k := range m {
			if n <= 0 {
				break
			}
			delete(m, k)
			n--
		}
	}
	trimMapHalf(authQueryMap(owner))
	trimMapHalf(authUserMap(owner))
}

// ApplyStickyAuthQuery：URL 带 ?auth= 则按 host 记住；无则回填已记凭据。
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
	owner := httpAuthOwner()
	if auth := strings.TrimSpace(q.Get("auth")); auth != "" {
		httpAuthMu.Lock()
		authQueryMap(owner)[host] = auth
		trimHTTPAuthHostsLocked(owner)
		httpAuthMu.Unlock()
		return rawURL
	}
	httpAuthMu.RLock()
	stored := authQueryByOwner[owner][host]
	httpAuthMu.RUnlock()
	if stored == "" {
		return rawURL
	}
	q.Set("auth", stored)
	u.RawQuery = EncodeQueryOkHTTP(q)
	return u.String()
}

// ApplyBasicFromUserInfo：URL userinfo 转 Basic，并按 host 记忆。
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
	owner := httpAuthOwner()
	httpAuthMu.Lock()
	authUserMap(owner)[host] = userInfo
	trimHTTPAuthHostsLocked(owner)
	httpAuthMu.Unlock()
	req.Header.Set("Authorization", BasicAuthHeader(userInfo))
}

// RetryAuthOn401：401 时用记忆凭据发 Digest/Basic 再请求一次。
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
		owner := httpAuthOwner()
		httpAuthMu.RLock()
		userInfo = authUserByOwner[owner][host]
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

// BasicAuthHeader 生成 Basic Authorization 头。
func BasicAuthHeader(userInfo string) string {
	if !strings.Contains(userInfo, ":") {
		userInfo += ":"
	}
	return "Basic " + base64.StdEncoding.EncodeToString([]byte(userInfo))
}

// DigestAuthHeader 生成 Digest Authorization 头。
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
