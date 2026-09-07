package spider

import (
	"bytes"
	"context"
	"crypto/md5"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"log"
	"net/url"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"time"

	"github.com/bobo/KOTV/internal/hostclient"
	"github.com/bobo/KOTV/internal/localproxy"
	"github.com/bobo/KOTV/internal/paths"
	appruntime "github.com/bobo/KOTV/internal/runtime"
	"github.com/bobo/KOTV/internal/util"
)

var (
	jarMu      sync.Mutex
	jarPath    string
	configBase string // 相对 spider.jar / ./js 等据此解析
	jarSpiders = map[string]*jarSpider{}
)

// 无 md5 的 jar 缓存有效期；过期后冷加载重新下载（每次都拉新包）。
const jarRefreshTTL = 30 * time.Minute

// 多用户：按 ScopeID 隔离配置基址，避免 A 换源覆盖 B 的相对路径解析。
var configBaseByClient sync.Map // ScopeID -> base URL

type jarSpider struct {
	key, api, ext, jar string
}

func newJarSpider(key, api, ext, jar string) Spider {
	jarMu.Lock()
	defer jarMu.Unlock()
	// 运行时分桶用 RuntimeUserID；jar 文件路径仍由 cacheJar 全局共享。
	uid := hostclient.RuntimeUserID()
	cacheKey := uid + "\x01" + strings.Join([]string{key, api, ext, jar}, "\x00")
	if s, ok := jarSpiders[cacheKey]; ok {
		return s
	}
	s := &jarSpider{key: key, api: api, ext: ext, jar: jar}
	jarSpiders[cacheKey] = s
	return s
}

func clearJarForUser(userID string) {
	userID = strings.TrimSpace(userID)
	if userID == "" {
		return
	}
	prefix := userID + "\x01"
	jarMu.Lock()
	for k := range jarSpiders {
		if strings.HasPrefix(k, prefix) {
			delete(jarSpiders, k)
		}
	}
	jarMu.Unlock()
}

func clearJar() {
	jarMu.Lock()
	jarSpiders = map[string]*jarSpider{}
	jarPath = ""
	configBase = ""
	jarMu.Unlock()
	// destroy spiders and drop loaders；向 bridge 发 clear；独立进程可按需 Kill 重建。
	req := bridgeRequest{Method: "clear"}
	if payload, err := json.Marshal(req); err == nil {
		_, _ = callJavaBridge(payload)
	}
}

// SetConfigBase 设置当前点播配置基址。有 ScopeID 时只写入该会话，不覆盖他人。
func SetConfigBase(base string) {
	base = strings.TrimSpace(base)
	if cid := hostclient.ScopeID(); cid != "" {
		if base == "" {
			configBaseByClient.Delete(cid)
		} else {
			configBaseByClient.Store(cid, base)
		}
		return
	}
	jarMu.Lock()
	configBase = base
	jarMu.Unlock()
}

// ConfigBase 返回当前配置基址（优先当前 ScopeID）。
func ConfigBase() string {
	if cid := hostclient.ScopeID(); cid != "" {
		if v, ok := configBaseByClient.Load(cid); ok {
			if s, _ := v.(string); s != "" {
				return s
			}
		}
	}
	jarMu.Lock()
	defer jarMu.Unlock()
	return configBase
}

func setRecentJar(jarSpec string) {
	jarSpec = strings.TrimSpace(jarSpec)
	if jarSpec == "" {
		jarMu.Lock()
		jp := jarPath
		jarMu.Unlock()
		if jp == "" {
			return
		}
		notifyParseJar(jp, true)
		return
	}
	dest, err := cacheJar(jarSpec, "", false)
	if err != nil {
		return
	}
	notifyParseJar(dest, true)
}

const parseJarBridgeTimeout = 30 * time.Second

// notifyParseJar BaseLoader.parseJar(jar, recent)：真加载 ClassLoader+Init+Proxy，可选设 recent。
func notifyParseJar(jarPath string, recent bool) {
	req := bridgeRequest{
		Method: "parseJar",
		Jar:    jarPath,
		Args: map[string]interface{}{
			"jar":    jarPath,
			"recent": recent,
		},
	}
	payload, _ := json.Marshal(req)
	callParseJarBridge(payload)
}

func callParseJarBridge(payload []byte) {
	ctx, cancel := context.WithTimeout(context.Background(), parseJarBridgeTimeout)
	defer cancel()
	if runtime.GOOS == "android" {
		if _, err := androidPostJarCtx(ctx, payload); err != nil {
			log.Printf("parseJar bridge: %v", err)
		}
		return
	}
	cid := hostclient.ScopeID()
	ctx2, end := beginJarCall(cid)
	defer end()
	ctx2, cancel2 := context.WithTimeout(ctx2, parseJarBridgeTimeout)
	defer cancel2()
	if _, err := bridgeForCurrent().callCtx(ctx2, payload); err != nil {
		log.Printf("parseJar bridge: %v", err)
	}
}

func notifyParseJarAsync(jarPath string, recent bool) {
	go notifyParseJar(jarPath, recent)
}

func notifyJarRecent(jarPath string) {
	notifyParseJar(jarPath, true)
}

// EnsureJar JarLoader.dex：下载并 parseJar，不改 recent（供 JS 站挂 Function 用）。
func EnsureJar(spec string, configBaseArg ...string) error {
	spec = strings.TrimSpace(spec)
	if spec == "" {
		return nil
	}
	base := ConfigBase()
	if len(configBaseArg) > 0 && strings.TrimSpace(configBaseArg[0]) != "" {
		base = strings.TrimSpace(configBaseArg[0])
	}
	dest, err := cacheJar(spec, base, false)
	if err != nil {
		return err
	}
	notifyParseJar(dest, false)
	return nil
}

// LoadJar 下载并缓存根 spider.jar。configBase 用于解析相对路径（如 spider.jar;md5;xxx）。
func LoadJar(spec string, configBaseArg ...string) error {
	spec = strings.TrimSpace(spec)
	if spec == "" {
		return nil
	}
	base := ConfigBase()
	if len(configBaseArg) > 0 && strings.TrimSpace(configBaseArg[0]) != "" {
		base = strings.TrimSpace(configBaseArg[0])
		SetConfigBase(base)
	}
	// assets:// 根 spider：UrlUtil.convert，走本地代理。
	if strings.HasPrefix(spec, "assets://") {
		localBase := fmt.Sprintf("http://127.0.0.1:%d", localproxy.Port())
		spec = localBase + "/" + strings.TrimPrefix(spec, "assets://")
	}
	dest, err := cacheJar(spec, base, true)
	if err != nil {
		return err
	}
	jarMu.Lock()
	jarPath = dest
	jarMu.Unlock()
	// VodConfig.parseJar(spider, true)：ClassLoader+Init+Proxy 后设为 recent。
	// 换源时不阻塞 HTTP：Init 可能在 WebView 配置页卡住，首页首次拉取时会再触发 parseJar。
	notifyParseJarAsync(dest, true)
	return nil
}

// normalizeLocalJarURL 把裸本地路径转成 file://，避免 HTTP 客户端报 unsupported protocol。
func normalizeLocalJarURL(downloadURL, configBase string) string {
	downloadURL = strings.TrimSpace(downloadURL)
	if downloadURL == "" {
		return ""
	}
	if strings.HasPrefix(downloadURL, "http://") || strings.HasPrefix(downloadURL, "https://") || strings.HasPrefix(strings.ToLower(downloadURL), "file:") {
		return downloadURL
	}
	// 绝对本地路径
	if filepath.IsAbs(downloadURL) {
		return pathToFileURL(downloadURL)
	}
	// 相对路径：相对配置文件目录
	baseDir := localConfigDir(configBase)
	if baseDir != "" {
		abs := filepath.Clean(filepath.Join(baseDir, filepath.FromSlash(downloadURL)))
		if st, err := os.Stat(abs); err == nil && !st.IsDir() {
			return pathToFileURL(abs)
		}
	}
	if abs, err := filepath.Abs(filepath.FromSlash(downloadURL)); err == nil {
		if st, err := os.Stat(abs); err == nil && !st.IsDir() {
			return pathToFileURL(abs)
		}
	}
	return downloadURL
}

func localConfigDir(configBase string) string {
	configBase = strings.TrimSpace(configBase)
	if configBase == "" {
		return ""
	}
	if p, ok := util.FileURLPath(configBase); ok {
		if st, err := os.Stat(p); err == nil && st.IsDir() {
			return p
		}
		return filepath.Dir(p)
	}
	if filepath.IsAbs(configBase) || strings.Contains(configBase, string(os.PathSeparator)) || strings.Contains(configBase, "/") {
		p := filepath.Clean(configBase)
		if st, err := os.Stat(p); err == nil {
			if st.IsDir() {
				return p
			}
			return filepath.Dir(p)
		}
		// 配置文件可能尚未 Stat 成功时仍按路径推目录
		if strings.HasSuffix(strings.ToLower(p), ".json") {
			return filepath.Dir(p)
		}
	}
	return ""
}

func pathToFileURL(abs string) string {
	abs = filepath.Clean(abs)
	u := url.URL{Scheme: "file", Path: filepath.ToSlash(abs)}
	return u.String()
}

func localFilePath(rawURL string) (string, bool) {
	rawURL = strings.TrimSpace(rawURL)
	if p, ok := util.FileURLPath(rawURL); ok {
		return p, true
	}
	if filepath.IsAbs(rawURL) {
		return rawURL, true
	}
	return "", false
}

func downloadBinary(rawURL, dest string) error {
	var (
		b   []byte
		err error
	)
	if localPath, ok := localFilePath(rawURL); ok {
		b, err = os.ReadFile(localPath)
	} else {
		b, err = util.HTTPGetBytes(rawURL, nil)
	}
	if err != nil {
		return err
	}
	if len(b) < 64 {
		return fmt.Errorf("文件过小 (%d bytes)", len(b))
	}
	if !bytes.HasPrefix(b, []byte("PK")) && !bytes.HasPrefix(b, []byte("dex\n")) {
		head := string(b)
		if len(head) > 80 {
			head = head[:80]
		}
		return fmt.Errorf("spider 不是 jar/dex（下载到了网页?）: %q", head)
	}
	tmp := dest + ".tmp"
	if err := os.WriteFile(tmp, b, 0o644); err != nil {
		return err
	}
	return os.Rename(tmp, dest)
}

type bridgeRequest struct {
	Method   string                 `json:"method"`
	Key      string                 `json:"key"`
	API      string                 `json:"api"`
	Ext      string                 `json:"ext"`
	Jar      string                 `json:"jar"`
	Args     map[string]interface{} `json:"args"`
	ClientID string                 `json:"clientId,omitempty"`
	UserID   string                 `json:"userId,omitempty"`
	RemoteUI bool                   `json:"remoteUi,omitempty"`
}

func fillBridgeClient(req *bridgeRequest) {
	req.ClientID = hostclient.ScopeID()
	req.UserID = hostclient.CurrentUserID()
	req.RemoteUI = hostclient.PublicBase() != ""
}

func (s *jarSpider) resolveJarPath() (string, error) {
	// 相对路径用 ApiConfig.url 作基址。
	if strings.TrimSpace(s.jar) != "" {
		dest, err := cacheJar(s.jar, ConfigBase(), false)
		if err != nil {
			return "", err
		}
		return dest, nil
	}
	jarMu.Lock()
	jp := jarPath
	jarMu.Unlock()
	if jp == "" {
		return "", fmt.Errorf("spider.jar 未加载，请检查配置中的 spider 字段")
	}
	return jp, nil
}

// cacheJar 下载并缓存 jar，返回本地路径（不改写全局 jarPath）。
// ;md5; 仅用于「本地缓存是否命中」；
// 无 md5、或 md5 不匹配时重新下载并照常加载，不因校验失败拒绝使用。
// allowOverride：仅根 LoadJar 允许 data/spider-override.jar 劫持；站点/JS jar 必须按各自 spec 缓存。
func cacheJar(spec, configBase string, allowOverride bool) (string, error) {
	spec = strings.TrimSpace(spec)
	if spec == "" {
		return "", fmt.Errorf("空 jar")
	}
	if allowOverride {
		// 仅 spider-override.jar 可劫持配置里的 spider。
		// data/spider.jar 若也劫持，会换成过期的 PC 瘦包（缺 Nostr 等类）。
		if override := filepath.Join(paths.Data(), "spider-override.jar"); fileExistsNonEmpty(override) {
			log.Printf("spider.jar 使用本地覆盖: %s", override)
			return override, nil
		}
	}
	path, expectMD5 := util.SplitJarSpec(spec)
	if strings.HasPrefix(expectMD5, "http://") || strings.HasPrefix(expectMD5, "https://") {
		value, err := util.HTTPGet(expectMD5, nil)
		if err != nil {
			log.Printf("spider.jar 远程 md5 读取失败，将直接下载: %v", err)
			expectMD5 = ""
		} else {
			expectMD5 = strings.TrimSpace(value)
		}
	}
	expectMD5 = strings.ToLower(strings.TrimSpace(expectMD5))
	base := strings.TrimSpace(configBase)
	if base == "" {
		base = ConfigBase()
	}
	downloadURL := path
	if !strings.HasPrefix(path, "http://") && !strings.HasPrefix(path, "https://") && !strings.HasPrefix(strings.ToLower(path), "file:") {
		downloadURL = util.ResolveJarURL(base, spec)
	}
	downloadURL = normalizeLocalJarURL(downloadURL, base)
	if downloadURL == "" {
		return "", fmt.Errorf("无效的 spider 地址: %s", spec)
	}
	// 相对路径仍未解析成绝对 URL：缺少配置基址时无法下载
	if !strings.HasPrefix(downloadURL, "http://") && !strings.HasPrefix(downloadURL, "https://") && !strings.HasPrefix(strings.ToLower(downloadURL), "file:") && !filepath.IsAbs(downloadURL) {
		return "", fmt.Errorf("无法解析相对 spider 路径 %q（配置基址为空或无效: %q）", path, base)
	}
	// file:// / 本地路径直接加载，不经 HTTP、不强制拷进缓存。
	if localPath, ok := localFilePath(downloadURL); ok {
		if st, err := os.Stat(localPath); err == nil && !st.IsDir() && st.Size() > 0 {
			if expectMD5 != "" {
				if actual := fileMD5(localPath); actual != expectMD5 {
					log.Printf("spider.jar 本地 md5 未命中 want=%s got=%s，仍按本地文件加载", expectMD5, actual)
				}
			}
			return localPath, nil
		}
		return "", fmt.Errorf("本地 spider.jar 不存在: %s", localPath)
	}
	// 按 jar 地址哈希缓存，不用配置里的 md5 当文件名。
	dest := paths.JarPath(util.MD5(downloadURL))
	if st, err := os.Stat(dest); err == nil && st.Size() > 0 {
		if expectMD5 == "" && time.Since(st.ModTime()) >= jarRefreshTTL {
			// 无 md5 的包冷加载时总是重新下载（不走磁盘命中）。
			// 这里用 TTL 折中；刷新失败沿用旧包，不因网络抖动把可用站点打挂。
			oldSum := fileMD5(dest)
			if err := downloadBinary(downloadURL, dest); err != nil {
				log.Printf("spider.jar 刷新失败，沿用旧缓存 (%s): %v", downloadURL, err)
			} else if newSum := fileMD5(dest); newSum != oldSum {
				// 磁盘包变了必须让 JVM/Dex 侧丢弃旧 ClassLoader+爬虫实例，
				// 否则 parseJar 命中内存缓存、跑的仍是旧类（需整包 clear）。
				if err := reloadBridgeJar(dest); err != nil {
					log.Printf("spider.jar 内存重载失败，沿用已加载类 (%s): %v", dest, err)
				}
			}
			return dest, nil
		}
		if expectMD5 == "" || fileMD5(dest) == expectMD5 {
			return dest, nil
		}
		// 有 md5 但缓存不一致 → 当作过期，重新下载
		_ = os.Remove(dest)
	}
	if err := downloadBinary(downloadURL, dest); err != nil {
		return "", fmt.Errorf("下载 spider.jar 失败 (%s): %w", downloadURL, err)
	}
	if expectMD5 != "" {
		if actual := fileMD5(dest); actual != expectMD5 {
			log.Printf("spider.jar md5 未命中缓存校验 want=%s got=%s，已按新包加载（不强制失败）", expectMD5, actual)
		}
	}
	return dest, nil
}

func fileMD5(path string) string {
	data, err := os.ReadFile(path)
	if err != nil {
		return ""
	}
	sum := md5.Sum(data)
	return hex.EncodeToString(sum[:])
}

func fileExistsNonEmpty(path string) bool {
	st, err := os.Stat(path)
	return err == nil && st.Size() > 0
}

func (s *jarSpider) call(method string, args map[string]interface{}) (string, error) {
	jp, err := s.resolveJarPath()
	if err != nil {
		return "", err
	}

	req := bridgeRequest{
		Method: method,
		// spider.siteKey 是站点 key；jar 缓存键由 bridge 用 md5(jar)+key 组合。
		Key:  s.key,
		API:  s.api,
		Ext:  s.ext,
		Jar:  jp,
		Args: args,
	}
	fillBridgeClient(&req)
	payload, _ := json.Marshal(req)

	raw, err := callJavaBridge(payload)
	if err != nil {
		return "", fmt.Errorf("爬虫调用失败: %w", err)
	}
	raw = trimCString(raw)
	if strings.HasPrefix(raw, "{") && strings.Contains(raw, `"error"`) {
		var errObj struct {
			Error string `json:"error"`
		}
		if json.Unmarshal([]byte(raw), &errObj) == nil && errObj.Error != "" {
			return "", fmt.Errorf("%s", errObj.Error)
		}
	}
	return raw, nil
}

func (s *jarSpider) Init(ext string) error {
	_, err := s.call("init", map[string]interface{}{"extend": ext})
	return err
}

func (s *jarSpider) HomeContent(filter bool) (string, error) {
	return s.call("homeContent", map[string]interface{}{"filter": filter})
}

func (s *jarSpider) HomeVideoContent() (string, error) {
	return s.call("homeVideoContent", nil)
}

func (s *jarSpider) CategoryContent(tid, pg string, filter bool, extend map[string]string) (string, error) {
	return s.call("categoryContent", map[string]interface{}{
		"tid": tid, "pg": pg, "filter": filter, "extend": extend,
	})
}

func (s *jarSpider) DetailContent(ids []string) (string, error) {
	return s.call("detailContent", map[string]interface{}{"ids": ids})
}

func (s *jarSpider) SearchContent(key string, quick bool, pg string) (string, error) {
	return s.call("searchContent", map[string]interface{}{"key": key, "quick": quick, "pg": pg})
}

func (s *jarSpider) PlayerContent(flag, id string, vipFlags []string) (string, error) {
	return s.call("playerContent", map[string]interface{}{"flag": flag, "id": id, "vipFlags": vipFlags})
}

func (s *jarSpider) LiveContent(url string) (string, error) {
	return s.call("liveContent", map[string]interface{}{"url": url})
}

func (s *jarSpider) Proxy(params map[string]string) (int, string, []byte, map[string]string, error) {
	raw, err := s.call("proxy", map[string]interface{}{"params": params})
	if err != nil {
		return 0, "", nil, nil, err
	}
	var resp struct {
		Status      int               `json:"status"`
		ContentType string            `json:"contentType"`
		Body        string            `json:"body"`
		BodyBase64  string            `json:"bodyBase64"`
		BodyFile    string            `json:"bodyFile"`
		BodyStream  string            `json:"bodyStream"`
		Headers     map[string]string `json:"headers"`
	}
	if err := json.Unmarshal([]byte(raw), &resp); err != nil {
		return 200, "text/plain", []byte(raw), nil, nil
	}
	if resp.BodyStream != "" || resp.BodyFile != "" {
		headers := resp.Headers
		if headers == nil {
			headers = map[string]string{}
		}
		if resp.BodyStream != "" {
			headers[ProxyBodyStreamHeader] = resp.BodyStream
		}
		if resp.BodyFile != "" {
			headers[ProxyBodyFileHeader] = resp.BodyFile
		}
		return resp.Status, resp.ContentType, nil, headers, nil
	}
	body := []byte(resp.Body)
	if resp.BodyBase64 != "" {
		if decoded, decErr := base64.StdEncoding.DecodeString(resp.BodyBase64); decErr == nil {
			body = decoded
		}
	}
	return resp.Status, resp.ContentType, body, resp.Headers, nil
}

func (s *jarSpider) Action(action string) (string, error) {
	return s.call("action", map[string]interface{}{"action": action})
}

func (s *jarSpider) ManualVideoCheck() (bool, error) {
	raw, err := s.call("manualVideoCheck", nil)
	if err != nil {
		return false, err
	}
	return parseJSTruthy(raw), nil
}

func (s *jarSpider) IsVideoFormat(u string) (bool, error) {
	raw, err := s.call("isVideoFormat", map[string]interface{}{"url": u})
	if err != nil {
		return false, err
	}
	return parseJSTruthy(raw), nil
}

// GlobalProxy ：siteKey / do=js / do=py / JAR static。
func GlobalProxy(params map[string]string) (int, string, []byte, map[string]string, error) {
	switch params["do"] {
	case "js":
		if s := recentJsSpider(); s != nil {
			return s.Proxy(params)
		}
		return 0, "", nil, nil, fmt.Errorf("no recent js spider")
	case "py":
		if s := recentPySpider(); s != nil {
			return s.Proxy(params)
		}
		return 0, "", nil, nil, fmt.Errorf("no recent py spider")
	}
	return jarProxy(params)
}

// JarProxy 保留给只想打 JAR 静态 Proxy 的调用方。
func JarProxy(params map[string]string) (int, string, []byte, map[string]string, error) {
	return jarProxy(params)
}

func jarProxy(params map[string]string) (int, string, []byte, map[string]string, error) {
	req := bridgeRequest{
		Method: "proxyGlobal",
		Args:   map[string]interface{}{"params": params},
	}
	fillBridgeClient(&req)
	payload, _ := json.Marshal(req)
	raw, err := callJavaBridge(payload)
	if err != nil {
		return 0, "", nil, nil, err
	}
	raw = trimCString(raw)
	var resp struct {
		Status      int               `json:"status"`
		ContentType string            `json:"contentType"`
		Body        string            `json:"body"`
		BodyBase64  string            `json:"bodyBase64"`
		BodyFile    string            `json:"bodyFile"`
		BodyStream  string            `json:"bodyStream"`
		Headers     map[string]string `json:"headers"`
		Error       string            `json:"error"`
	}
	if err := json.Unmarshal([]byte(raw), &resp); err != nil {
		return 0, "", nil, nil, err
	}
	if resp.Error != "" {
		return 0, "", nil, nil, fmt.Errorf("%s", resp.Error)
	}
	if resp.BodyStream != "" || resp.BodyFile != "" {
		headers := resp.Headers
		if headers == nil {
			headers = map[string]string{}
		}
		if resp.BodyStream != "" {
			headers[ProxyBodyStreamHeader] = resp.BodyStream
		}
		if resp.BodyFile != "" {
			headers[ProxyBodyFileHeader] = resp.BodyFile
		}
		return resp.Status, resp.ContentType, nil, headers, nil
	}
	if resp.Status == 0 && resp.ContentType == "" && resp.Body == "" && resp.BodyBase64 == "" {
		return 0, "", nil, nil, fmt.Errorf("invalid proxy response")
	}
	body := []byte(resp.Body)
	if resp.BodyBase64 != "" {
		if decoded, decodeErr := base64.StdEncoding.DecodeString(resp.BodyBase64); decodeErr == nil {
			body = decoded
		}
	}
	return resp.Status, resp.ContentType, body, resp.Headers, nil
}

func (s *jarSpider) Destroy() {}

// JsonExt 调用 spider.jar 中 com.github.catvod.parser.Json{key}.parse
func JsonExt(parseKey string, jxs map[string]string, webURL string) (string, error) {
	return callJarMethod("jsonExt", map[string]interface{}{
		"parseKey": parseKey,
		"jxs":      jxs,
		"url":      webURL,
	})
}

// JsonExtMix 调用 Mix{key}.parse
func JsonExtMix(flag, parseKey, name string, jxs map[string]map[string]string, webURL string) (string, error) {
	return callJarMethod("jsonExtMix", map[string]interface{}{
		"parseKey": parseKey,
		"name":     name,
		"flag":     flag,
		"jxs":      jxs,
		"url":      webURL,
	})
}

// JsParse createFun：从 jar ClassLoader 调 pdfh/pdfa/pd/pdfl（经 bridge RPC）。
func JsParse(jar, op, html, rule, url, texts, urls string) (value string, list []string, err error) {
	args := map[string]interface{}{
		"op":    op,
		"html":  html,
		"rule":  rule,
		"url":   url,
		"texts": texts,
		"urls":  urls,
	}
	jar = strings.TrimSpace(jar)
	if jar != "" {
		// 必须传本地已缓存路径。相对 spider.jar;md5;… 会让 Android 当成文件名反复失败。
		if dest, e := cacheJar(jar, ConfigBase(), false); e == nil && strings.TrimSpace(dest) != "" {
			args["jar"] = dest
		} else if e != nil {
			log.Printf("jsParse cacheJar skip (%s): %v", jar, e)
		}
	}
	raw, err := callJarMethod("jsParse", args)
	if err != nil {
		return "", nil, err
	}
	var resp struct {
		Value string   `json:"value"`
		List  []string `json:"list"`
		Error string   `json:"error"`
	}
	if json.Unmarshal([]byte(raw), &resp) != nil {
		return strings.TrimSpace(raw), nil, nil
	}
	if resp.Error != "" {
		return "", nil, fmt.Errorf("%s", resp.Error)
	}
	return resp.Value, resp.List, nil
}

// reloadBridgeJar 磁盘包刷新后让 bridge 丢弃该 jar 的旧 ClassLoader+爬虫并重载。
func reloadBridgeJar(jarPath string) error {
	req := bridgeRequest{
		Method: "reloadJar",
		Jar:    jarPath,
	}
	fillBridgeClient(&req)
	payload, err := json.Marshal(req)
	if err != nil {
		return err
	}
	raw, err := callJavaBridge(payload)
	if err != nil {
		return err
	}
	raw = trimCString(raw)
	var errObj struct {
		Error string `json:"error"`
	}
	if json.Unmarshal([]byte(raw), &errObj) == nil && errObj.Error != "" {
		return fmt.Errorf("%s", errObj.Error)
	}
	return nil
}

func callJarMethod(method string, args map[string]interface{}) (string, error) {
	// jsonExt/jsonExtMix 只依赖 Java 侧 recent ClassLoader，
	// 不经 getSpider，也不用假 csp_Null 覆盖 recent。
	req := bridgeRequest{
		Method: method,
		Args:   args,
	}
	fillBridgeClient(&req)
	payload, _ := json.Marshal(req)
	raw, err := callJavaBridge(payload)
	if err != nil {
		return "", fmt.Errorf("解析调用失败: %w", err)
	}
	raw = trimCString(raw)
	var errObj struct {
		Error string `json:"error"`
	}
	if json.Unmarshal([]byte(raw), &errObj) == nil && errObj.Error != "" {
		return "", fmt.Errorf("%s", errObj.Error)
	}
	return raw, nil
}

func findBridgeJar() string {
	exist := func(p string) string {
		if st, err := os.Stat(p); err == nil && !st.IsDir() && st.Size() > 0 {
			abs, _ := filepath.Abs(p)
			return abs
		}
		return ""
	}
	// 1) 可执行文件旁（发行包）
	if exe, err := os.Executable(); err == nil {
		if resolved, err := filepath.EvalSymlinks(exe); err == nil {
			exe = resolved
		}
		dir := filepath.Dir(exe)
		for _, p := range []string{
			filepath.Join(dir, "bridge", "spider-bridge.jar"),
			filepath.Join(dir, "spider-bridge.jar"),
			filepath.Join(dir, "runtime", "bridge", "spider-bridge.jar"),
		} {
			if got := exist(p); got != "" {
				return got
			}
		}
	}
	// 2) 开发态：仓库根 bridge/（优先于可能过期的 runtime/ 副本）
	for _, p := range []string{
		"bridge/spider-bridge.jar",
		"spider-bridge.jar",
		filepath.Join(paths.Data(), "spider-bridge.jar"),
	} {
		if got := exist(p); got != "" {
			return got
		}
	}
	return appruntime.BridgeJAR()
}
