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
	"sync/atomic"
	"time"

	"github.com/bobo/KOTV/internal/hostclient"
	"github.com/bobo/KOTV/internal/localproxy"
	"github.com/bobo/KOTV/internal/paths"
	appruntime "github.com/bobo/KOTV/internal/runtime"
	"github.com/bobo/KOTV/internal/util"
)

var (
	jarMu         sync.Mutex
	jarPathByUser sync.Map // RuntimeUserID -> 根 jar 本地路径；本机键为空
	configBase    string   // 相对 spider.jar / ./js 等据此解析
	jarSpiders    = map[string]*jarSpider{}
)

func currentJarPath() string {
	v, ok := jarPathByUser.Load(hostclient.RuntimeUserID())
	if !ok {
		return ""
	}
	s, _ := v.(string)
	return s
}

// CurrentJarPath 当前租户根 jar 本地路径（空则 CSP 站可能无法 resolve）。
func CurrentJarPath() string { return currentJarPath() }

func setCurrentJarPath(path string) {
	uid := hostclient.RuntimeUserID()
	if path == "" {
		jarPathByUser.Delete(uid)
		return
	}
	jarPathByUser.Store(uid, path)
}

func clearAllJarPaths() {
	jarPathByUser.Range(func(k, _ any) bool {
		jarPathByUser.Delete(k)
		return true
	})
}

// 无 md5 jar：仅 LoadJar/clearJar 换世代后首次强制刷新（非每个业务 call）。
var (
	jarRefreshGen     atomic.Uint64
	jarNoMD5Refreshed sync.Map // downloadURL -> gen
	// 同一租户、同一路径的 parseJar 去重（单 bridge；键含 RuntimeUserID，不能按路径全局跳过）。
	parseJarNotified sync.Map // jarRunKey -> struct{}
	parseJarFlights  sync.Map // jarRunKey -> *parseJarFlight
	jarRecentByUser  sync.Map // RuntimeUserID -> 已设为 recent 的本地路径
	// 卸载时加一。更早发出的加载请求晚到也不再装。
	jarWireGen atomic.Uint64
	// 清缓存重载：LoadJar 同步 parseJar，避免首页先拉站时 ClassLoader 未就绪。
	forceSyncParseJar atomic.Bool
)

// 多用户：按 ScopeID 隔离配置基址，避免 A 换源覆盖 B 的相对路径解析。
var configBaseByClient sync.Map // ScopeID -> base URL

type jarSpider struct {
	key, api, ext, jar string
}

func newJarSpider(key, api, ext, jar string) Spider {
	jarMu.Lock()
	defer jarMu.Unlock()
	// 进程/指针按 RuntimeUserID 分桶；jar 包体经 cacheJar 全局共享（JarCache/md5）。
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
	dropJarSpiders(userID+"\x01", false)
}

// ApplyConfigJars 切仓成功后：清当前租户 bridge 态，再装新仓库根 jar。不杀 JVM、不 clearAll。
func ApplyConfigJars(nextURL, nextRoot string) error {
	if sid := hostclient.ScopeID(); sid != "" {
		SoftCancelForClient(sid)
	}
	clearRuntimeJars()
	releaseConfigScripts()
	nextRoot = strings.TrimSpace(nextRoot)
	if nextRoot == "" {
		return nil
	}
	return LoadJar(nextRoot, nextURL)
}

func jarDownloadURL(spec, configURL string) (downloadURL, sum string, ok bool) {
	spec = strings.TrimSpace(spec)
	if spec == "" {
		return "", "", false
	}
	if strings.HasPrefix(spec, "assets://") {
		spec = fmt.Sprintf("http://127.0.0.1:%d/%s", localproxy.Port(), strings.TrimPrefix(spec, "assets://"))
	}
	path, sum := util.SplitJarSpec(spec)
	sum = strings.ToLower(strings.TrimSpace(sum))
	base := strings.TrimSpace(configURL)
	if base == "" {
		base = ConfigBase()
	}
	downloadURL = path
	if !strings.HasPrefix(path, "http://") && !strings.HasPrefix(path, "https://") && !strings.HasPrefix(strings.ToLower(path), "file:") {
		downloadURL = util.ResolveJarURL(base, spec)
	}
	downloadURL = normalizeLocalJarURL(downloadURL, base)
	if downloadURL == "" {
		return "", "", false
	}
	return downloadURL, sum, true
}

func rootOverridePath() string {
	override := filepath.Join(paths.Data(), "spider-override.jar")
	if fileExistsNonEmpty(override) {
		return override
	}
	return ""
}

func clearRuntimeJars() {
	uid := hostclient.RuntimeUserID()
	dropJarSpiders(uid+"\x01", false)
	setCurrentJarPath("")
	// 单桥：只清当前租户（本机空 uid → shared），禁止 clearAll 误卸全体 ClassLoader。
	tenant := uid
	if tenant == "" {
		tenant = "shared"
	}
	clearBridgeTenant(tenant)
}

func releaseConfigScripts() {
	// 只毁当前用户 Py/JS 池；模块字节缓存全局共享，留给 Clear/Reset 全清。
	destroyScripts(hostclient.RuntimeUserID()+"\x01", false)
}

func clearJar() {
	dropJarSpiders("", true)
	clearAllJarPaths()
	jarMu.Lock()
	configBase = ""
	jarMu.Unlock()
	bumpJarRefreshGen()
	// 清磁盘缓存：唯一 bridge 上 clearAll（卸全体 ClassLoader）。
	sendBridgeClearAll()
}

func dropJarSpiders(prefix string, all bool) {
	jarMu.Lock()
	defer jarMu.Unlock()
	if all {
		jarSpiders = map[string]*jarSpider{}
		return
	}
	for k := range jarSpiders {
		if strings.HasPrefix(k, prefix) {
			delete(jarSpiders, k)
		}
	}
}

// sendBridgeClearAll 向唯一 bridge 下发无 userId 的 clear → Java clearAll（卸 ClassLoader）。
func sendBridgeClearAll() {
	jarWireGen.Add(1)
	payload, err := json.Marshal(bridgeRequest{Method: "clear"})
	if err != nil {
		log.Printf("jar 卸载失败: %v", err)
		return
	}
	postBridgeRPC(payload)
}

// clearBridgeTenant 单 JVM：RPC 只清该租户 spiders/recent/proxy/NetProfiles，不卸 ClassLoader、不杀进程。
// userID 空串视为 "shared"（本机共享桶）。
func clearBridgeTenant(userID string) {
	userID = strings.TrimSpace(userID)
	if userID == "" {
		userID = "shared"
	}
	forgetJarRecent(userID)
	if userID == "shared" {
		forgetJarRecent("")
	}
	jarWireGen.Add(1)
	req := bridgeRequest{
		Method: "clearTenant",
		UserID: userID,
		Args: map[string]interface{}{
			"userId": userID,
		},
	}
	payload, err := json.Marshal(req)
	if err != nil {
		log.Printf("jar clearTenant 序列化失败: %v", err)
		return
	}
	postBridgeRPC(payload)
}

// postBridgeRPC 安卓 SpiderService / 桌面唯一 javaBridge 的短超时 /jar/call。
func postBridgeRPC(payload []byte) {
	postBridgeClearPayload(&javaBridge, payload)
}

func postBridgeClearPayload(br *javaBridgeClient, payload []byte) {
	if runtime.GOOS == "android" {
		if _, err := androidPostJarShort(payload); err != nil {
			log.Printf("jar bridge rpc: %v", err)
		}
		return
	}
	if br == nil {
		br = &javaBridge
	}
	base := br.currentBaseURL()
	if base == "" {
		return
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	if _, err := br.httpPostCtx(ctx, payload); err != nil {
		log.Printf("jar 卸载失败: %v", err)
	}
}

// bumpJarRefreshGen 全局清 jar 就绪态（仅 clearJar / 清磁盘缓存）。单用户 LoadJar 用 bumpJarRefreshForCaller。
func bumpJarRefreshGen() {
	jarRefreshGen.Add(1)
	jarNoMD5Refreshed.Range(func(k, _ any) bool {
		jarNoMD5Refreshed.Delete(k)
		return true
	})
	parseJarNotified.Range(func(k, _ any) bool {
		parseJarNotified.Delete(k)
		return true
	})
	parseJarFlights.Range(func(k, _ any) bool {
		parseJarFlights.Delete(k)
		return true
	})
	forgetAllJarRecent()
}

// bumpJarRefreshForCaller 只清当前租户 Go 侧 jar 就绪态，不逼其它租户重 parse / 重下无关 URL。
func bumpJarRefreshForCaller() {
	clearJarGoStateForRuntime(hostclient.RuntimeUserID())
}

type parseJarFlight struct {
	done chan struct{}
	err  error
}

// WithSyncLoadJar 在 fn 期间让 LoadJar 同步 parseJar（清缓存重载用）。
func WithSyncLoadJar(fn func() error) error {
	forceSyncParseJar.Store(true)
	defer forceSyncParseJar.Store(false)
	return fn()
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
	var dest string
	if jarSpec == "" {
		dest = currentJarPath()
		if dest == "" {
			return
		}
	} else {
		var err error
		dest, err = cacheJar(jarSpec, "", false)
		if err != nil || dest == "" {
			return
		}
	}
	if jarRecentCanSkip(dest) {
		return
	}
	if err := notifyParseJar(dest, true); err != nil {
		forgetJarRecent(hostclient.RuntimeUserID())
	}
}

func rememberJarRecent(path string) {
	path = strings.TrimSpace(path)
	if path == "" {
		return
	}
	jarRecentByUser.Store(hostclient.RuntimeUserID(), path)
}

func forgetJarRecent(userID string) {
	jarRecentByUser.Delete(strings.TrimSpace(userID))
}

// clearJarGoStateForRuntime 清某运行时桶的 Go 侧 jar 就绪态（JVM 进程另杀/另启）。
// userID 空=本机共享；非空=该远端用户。
// 必须清 parseJarNotified/flights：否则重建后会误判「已 parse」而跳过装载。
func clearJarGoStateForRuntime(userID string) {
	userID = strings.TrimSpace(userID)
	forgetJarRecent(userID)
	jarPathByUser.Delete(userID)
	prefix := userID + "\x01"
	purgePrefixed := func(m *sync.Map) {
		m.Range(func(k, _ any) bool {
			if s, ok := k.(string); ok && strings.HasPrefix(s, prefix) {
				m.Delete(k)
			}
			return true
		})
	}
	purgePrefixed(&parseJarNotified)
	purgePrefixed(&parseJarFlights)
	if userID == "" {
		return
	}
	// 与 clearNetConfigForUser 同口径：按 Scope 归属清配置基址。
	configBaseByClient.Range(func(k, _ any) bool {
		if s, ok := k.(string); ok && hostclient.UserIDFromScope(s) == userID {
			configBaseByClient.Delete(k)
		}
		return true
	})
}

func dropJarRecent(path string) {
	uid := hostclient.RuntimeUserID()
	if cur, _ := jarRecentByUser.Load(uid); cur == path {
		forgetJarRecent(uid)
	}
}

func forgetAllJarRecent() {
	jarRecentByUser.Range(func(k, _ any) bool {
		jarRecentByUser.Delete(k)
		return true
	})
}

func jarRunKey(path string) string {
	return hostclient.RuntimeUserID() + "\x01" + path
}

func jarRecentCanSkip(path string) bool {
	path = strings.TrimSpace(path)
	if path == "" {
		return false
	}
	v, ok := jarRecentByUser.Load(hostclient.RuntimeUserID())
	if !ok {
		return false
	}
	cur, _ := v.(string)
	if cur != path {
		return false
	}
	return bridgeAliveForRecent()
}

var bridgeAliveForRecent = func() bool {
	if runtime.GOOS == "android" {
		return androidJarReachable.Load()
	}
	b := bridgeForCurrent()
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.aliveLocked()
}

const parseJarBridgeTimeout = javaBridgeCallTimeout

// notifyParseJar parseJar(jar, recent)：真加载 ClassLoader+Init+Proxy，可选设 recent。
func notifyParseJar(jarPath string, recent bool) error {
	jarPath = strings.TrimSpace(jarPath)
	if jarPath == "" {
		return nil
	}
	// recent=false（EnsureJar）：同一用户、同一路径只真正 parse 一次；进行中则等待，已完成则跳过。
	// recent=true（LoadJar）：换源须设 recent，仍通知；若同 dest 进行中则先等完再跑。
	// 代数在进入时记下。卸载之后才把请求发出去，晚到的旧请求不会再装。
	gen := jarWireGen.Load()
	for {
		key := jarRunKey(jarPath)
		if !recent {
			if _, done := parseJarNotified.Load(key); done {
				return nil
			}
		}
		flight := &parseJarFlight{done: make(chan struct{})}
		actual, loaded := parseJarFlights.LoadOrStore(key, flight)
		if loaded {
			existing := actual.(*parseJarFlight)
			<-existing.done
			if existing.err == nil && !recent {
				return nil
			}
			if existing.err != nil && !recent {
				return existing.err
			}
			continue
		}
		req := bridgeRequest{
			Method: "parseJar",
			Jar:    jarPath,
			Args: map[string]interface{}{
				"jar":    jarPath,
				"recent": recent,
			},
		}
		fillBridgeClient(&req)
		req.JarGen = gen
		payload, _ := json.Marshal(req)
		flight.err = callParseJar(payload)
		if flight.err == nil {
			parseJarNotified.Store(key, struct{}{})
			if recent {
				rememberJarRecent(jarPath)
			}
		}
		parseJarFlights.CompareAndDelete(key, flight)
		close(flight.done)
		return flight.err
	}
}

var callParseJar = callParseJarBridge

func callParseJarBridge(payload []byte) error {
	cid := hostclient.ScopeID()
	ctx, end := beginJarCall(cid)
	defer end()
	ctx, cancel := context.WithTimeout(ctx, parseJarBridgeTimeout)
	defer cancel()
	if runtime.GOOS == "android" {
		if _, err := androidPostJarCtx(ctx, payload); err != nil {
			log.Printf("parseJar bridge: %v", err)
			return err
		}
		return nil
	}
	if _, err := bridgeForCurrent().callCtx(ctx, payload); err != nil {
		log.Printf("parseJar bridge: %v", err)
		return err
	}
	return nil
}

func notifyParseJarAsync(jarPath string, recent bool) {
	parent := hostclient.Snapshot()
	go func() {
		done := hostclient.Bind(parent)
		defer done()
		_ = notifyParseJar(jarPath, recent)
	}()
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
	return notifyParseJar(dest, false)
}

// EnsureRootJar 下载并 parse 根 spider.jar，写入当前租户 jar 路径指针（供 CSP 空 jar 站 resolve）。
// 不 bump 刷新世代；失败返回错误，不杀唯一 JVM。
func EnsureRootJar(spec string, configBaseArg ...string) error {
	spec = strings.TrimSpace(spec)
	if spec == "" {
		return nil
	}
	base := ConfigBase()
	if len(configBaseArg) > 0 && strings.TrimSpace(configBaseArg[0]) != "" {
		base = strings.TrimSpace(configBaseArg[0])
		SetConfigBase(base)
	}
	dest, err := cacheJar(spec, base, false)
	if err != nil {
		return err
	}
	setCurrentJarPath(dest)
	return notifyParseJar(dest, true)
}

// LoadJar 下载并缓存根 spider.jar。configBase 用于解析相对路径（如 spider.jar;md5;xxx）。
func LoadJar(spec string, configBaseArg ...string) error {
	spec = strings.TrimSpace(spec)
	if spec == "" {
		return nil
	}
	bumpJarRefreshForCaller()
	base := ConfigBase()
	if len(configBaseArg) > 0 && strings.TrimSpace(configBaseArg[0]) != "" {
		base = strings.TrimSpace(configBaseArg[0])
		SetConfigBase(base)
	}
	dest, err := cacheJar(spec, base, true)
	if err != nil {
		return err
	}
	setCurrentJarPath(dest)
	// VodConfig.parseJar(spider, true)：ClassLoader+Init+Proxy 后设为 recent。
	// 换源默认不阻塞 HTTP（Init 可能在 WebView 配置页卡住）；清缓存路径 WithSyncLoadJar 同步。
	if forceSyncParseJar.Load() {
		_ = notifyParseJar(dest, true)
	} else {
		notifyParseJarAsync(dest, true)
	}
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
	return doOnce("jar:"+dest, func() error {
		return writeJarFile(rawURL, dest)
	})
}

func writeJarFile(rawURL, dest string) error {
	var (
		b   []byte
		err error
	)
	if localPath, ok := localFilePath(rawURL); ok {
		b, err = os.ReadFile(localPath)
	} else {
		ctx, end := BeginScopeHTTP(hostclient.ScopeID())
		b, err = util.HTTPGetBytesInsecureCtx(ctx, rawURL, nil)
		end()
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
	return writeFileAtomic(dest, b)
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
	Username string                 `json:"username,omitempty"`
	RemoteUI bool                   `json:"remoteUi,omitempty"`
	JarGen   uint64                 `json:"jarGen"`
}

func fillBridgeClient(req *bridgeRequest) {
	req.ClientID = hostclient.ScopeID()
	req.UserID = hostclient.CurrentUserID()
	req.Username = hostclient.CurrentUsername()
	req.RemoteUI = hostclient.PublicBase() != ""
	req.JarGen = jarWireGen.Load()
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
	jp := currentJarPath()
	if jp == "" {
		return "", fmt.Errorf("spider.jar 未加载，请检查配置中的 spider 字段")
	}
	return jp, nil
}

// cacheJar 下载并缓存 jar，返回本地路径（不改写当前用户的根 jar 路径）。
// ;md5; 仅用于「本地缓存是否命中」；
// 无 md5、或 md5 不匹配时重新下载并照常加载，不因校验失败拒绝使用。
// allowOverride：仅根 LoadJar 允许 data/spider-override.jar 劫持；站点/JS jar 必须按各自 spec 缓存。
func cacheJar(spec, configBase string, allowOverride bool) (string, error) {
	spec = strings.TrimSpace(spec)
	if spec == "" {
		return "", fmt.Errorf("空 jar")
	}
	wireGen := jarWireGen.Load()
	if allowOverride {
		// 仅 spider-override.jar 可劫持配置里的 spider。
		// data/spider.jar 若也劫持，会换成过期的 PC 瘦包（缺 Nostr 等类）。
		if override := rootOverridePath(); override != "" {
			log.Printf("spider.jar 使用本地覆盖: %s", override)
			return override, nil
		}
	}
	downloadURL, expectMD5, ok := jarDownloadURL(spec, configBase)
	if !ok || downloadURL == "" {
		return "", fmt.Errorf("无效的 spider 地址: %s", spec)
	}
	if strings.HasPrefix(expectMD5, "http://") || strings.HasPrefix(expectMD5, "https://") {
		value, err := util.HTTPGetInsecure(expectMD5, nil)
		if err != nil {
			log.Printf("spider.jar 远程 md5 读取失败，将直接下载: %v", err)
			expectMD5 = ""
		} else {
			expectMD5 = strings.ToLower(strings.TrimSpace(value))
		}
	}
	base := strings.TrimSpace(configBase)
	if base == "" {
		base = ConfigBase()
	}
	// 相对路径仍未解析成绝对 URL：缺少配置基址时无法下载
	if !strings.HasPrefix(downloadURL, "http://") && !strings.HasPrefix(downloadURL, "https://") && !strings.HasPrefix(strings.ToLower(downloadURL), "file:") && !filepath.IsAbs(downloadURL) {
		return "", fmt.Errorf("无法解析相对 spider 路径 %q（配置基址为空或无效: %q）", spec, base)
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
	gen := jarRefreshGen.Load()
	// 根 LoadJar：只失效本 URL 的无 md5 命中标记，不扫全局其它地址。
	if allowOverride && expectMD5 == "" {
		jarNoMD5Refreshed.Delete(downloadURL)
	}
	hadCache := false
	oldSum := ""
	if st, err := os.Stat(dest); err == nil && st.Size() > 0 {
		hadCache = true
		if expectMD5 == "" {
			// 无 md5：仅本世代首次刷新（LoadJar 删条目 / clear 全局 bump 后）；同世代业务 call 用磁盘包。
			if v, ok := jarNoMD5Refreshed.Load(downloadURL); ok {
				if g, _ := v.(uint64); g == gen {
					return dest, nil
				}
			}
		}
		oldSum = fileMD5(dest)
		if expectMD5 == "" {
			if err := downloadBinary(downloadURL, dest); err != nil {
				log.Printf("spider.jar 刷新失败，沿用旧缓存 (%s): %v", downloadURL, err)
			} else if newSum := fileMD5(dest); newSum != oldSum {
				if err := reloadBridgeJar(dest, wireGen); err != nil {
					log.Printf("spider.jar 内存重载失败，沿用已加载类 (%s): %v", dest, err)
				}
			}
			jarNoMD5Refreshed.Store(downloadURL, gen)
			return dest, nil
		}
		if oldSum == expectMD5 {
			return dest, nil
		}
		// 有 md5 但缓存不一致 → 重新下载（不先删，失败可沿用旧包）
	}
	if err := downloadBinary(downloadURL, dest); err != nil {
		if hadCache {
			log.Printf("spider.jar 下载失败，沿用旧缓存 (%s): %v", downloadURL, err)
			return dest, nil
		}
		return "", fmt.Errorf("下载 spider.jar 失败 (%s): %w", downloadURL, err)
	}
	if expectMD5 == "" {
		jarNoMD5Refreshed.Store(downloadURL, gen)
	}
	if hadCache {
		if newSum := fileMD5(dest); newSum != oldSum {
			if err := reloadBridgeJar(dest, wireGen); err != nil {
				log.Printf("spider.jar 内存重载失败，沿用已加载类 (%s): %v", dest, err)
			}
		}
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
	gen := jarWireGen.Load()
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
	req.JarGen = gen
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
	args := map[string]interface{}{"key": key, "quick": quick}
	if pg != "" && pg != "1" {
		args["pg"] = pg
	}
	return s.call("searchContent", args)
}

func (s *jarSpider) PlayerContent(flag, id string, vipFlags []string) (string, error) {
	return s.call("playerContent", map[string]interface{}{"flag": flag, "id": id, "vipFlags": vipFlags})
}

func (s *jarSpider) LiveContent(url string) (string, error) {
	return s.call("liveContent", map[string]interface{}{"url": url})
}

// bridgeProxyResponse Java 桥 proxy / proxyGlobal 的返回。
type bridgeProxyResponse struct {
	Status      int               `json:"status"`
	ContentType string            `json:"contentType"`
	Body        string            `json:"body"`
	BodyBase64  string            `json:"bodyBase64"`
	BodyFile    string            `json:"bodyFile"`
	BodyStream  string            `json:"bodyStream"`
	Headers     map[string]string `json:"headers"`
	Error       string            `json:"error"`
}

// result 转成 Proxy 返回值：bodyStream / bodyFile 放进响应头交给 HTTP 层，其余取 body（有 bodyBase64 时用它）。
func (r bridgeProxyResponse) result() (int, string, []byte, map[string]string) {
	if r.BodyStream != "" || r.BodyFile != "" {
		headers := r.Headers
		if headers == nil {
			headers = map[string]string{}
		}
		if r.BodyStream != "" {
			headers[ProxyBodyStreamHeader] = r.BodyStream
		}
		if r.BodyFile != "" {
			headers[ProxyBodyFileHeader] = r.BodyFile
		}
		return r.Status, r.ContentType, nil, headers
	}
	body := []byte(r.Body)
	if r.BodyBase64 != "" {
		if decoded, err := base64.StdEncoding.DecodeString(r.BodyBase64); err == nil {
			body = decoded
		}
	}
	return r.Status, r.ContentType, body, r.Headers
}

func (s *jarSpider) Proxy(params map[string]string) (int, string, []byte, map[string]string, error) {
	raw, err := s.call("proxy", map[string]interface{}{"params": params})
	if err != nil {
		return 0, "", nil, nil, err
	}
	var resp bridgeProxyResponse
	if err := json.Unmarshal([]byte(raw), &resp); err != nil {
		return 200, "text/plain", []byte(raw), nil, nil
	}
	status, ct, body, headers := resp.result()
	return status, ct, body, headers, nil
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
	var resp bridgeProxyResponse
	if err := json.Unmarshal([]byte(raw), &resp); err != nil {
		return 0, "", nil, nil, err
	}
	if resp.Error != "" {
		return 0, "", nil, nil, fmt.Errorf("%s", resp.Error)
	}
	if resp.BodyStream == "" && resp.BodyFile == "" &&
		resp.Status == 0 && resp.ContentType == "" && resp.Body == "" && resp.BodyBase64 == "" {
		return 0, "", nil, nil, fmt.Errorf("invalid proxy response")
	}
	status, ct, body, headers := resp.result()
	return status, ct, body, headers, nil
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
func reloadBridgeJar(jarPath string, gen uint64) error {
	parseJarNotified.Delete(jarRunKey(jarPath))
	dropJarRecent(jarPath)
	return callBridgeJar(jarPath, "reloadJar", gen)
}

func callBridgeJar(jarPath, method string, gen uint64) error {
	req := bridgeRequest{
		Method: method,
		Jar:    jarPath,
	}
	fillBridgeClient(&req)
	req.JarGen = gen
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
