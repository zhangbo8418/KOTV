package spider

import (
	"bufio"
	"bytes"
	"context"
	"crypto/md5"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log"
	"net/http"
	"net/http/httputil"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/bobo/KOTV/internal/hostclient"
	"github.com/bobo/KOTV/internal/localproxy"
	"github.com/bobo/KOTV/internal/paths"
	"github.com/bobo/KOTV/internal/playproxy"
	appruntime "github.com/bobo/KOTV/internal/runtime"
	"github.com/bobo/KOTV/internal/util"

	_ "embed"
)

// ErrNodeInterrupted 表示 Node 调用被软取消或超时放弃。
var ErrNodeInterrupted = errors.New("node 调用已中断")

//go:embed noderunner.js
var nodeRunnerSrc string

const (
	nodeStartTimeout   = 45 * time.Second
	nodeConfigTimeout  = 15 * time.Second
	nodeCallTimeout    = 45 * time.Second
	nodeRestartBackoff = 2 * time.Second
	nodeMaxBackoff     = 30 * time.Second
)

// NodeHost 管理猫爪 Node 源包：下载、启动、反代与消息回调。
// 本机共享一份；远端租户按 RuntimeUserID 独立桶（JAR 为单 JVM 内租户；JS/Py 另池）。
type NodeHost struct {
	ownerUID    string // RuntimeUserID；空串=本机共享
	mu          sync.Mutex
	pkgs        map[string]*nodePkg // id → pkg
	apiIndex    map[string]string   // /spider/... → pkgID
	rootAliases map[string]struct{} // OPENWEB 登记的根路径首段（页内绝对路径反代）
	runner      string
}

type nodePkg struct {
	id, pkgURL, dir, dataDir string
	indexJS, configJS        string
	ownerUID                 string
	host                     *NodeHost

	mu       sync.Mutex
	cmd      *exec.Cmd
	port     int
	stopping bool
	backoff  time.Duration
	caller   callerSnap
}

// 进行中的 Node HTTP 调用，按 ScopeID 软取消；取消/超时后回收**该用户桶**内源包进程。
type nodeInflight struct {
	id       uint64
	clientID string // ScopeID
	ownerUID string // RuntimeUserID（空=共享桶）
	pkgID    string
	cancel   context.CancelFunc
}

var (
	sharedNodeHost = &NodeHost{
		pkgs:     map[string]*nodePkg{},
		apiIndex: map[string]string{},
	}
	userNodeHostsMu sync.Mutex
	userNodeHosts   = map[string]*NodeHost{}

	nodeInflightMu sync.Mutex
	nodeInflightQ  = map[uint64]*nodeInflight{}
	nodeCallSeq    atomic.Uint64
)

func newNodeHost(ownerUID string) *NodeHost {
	return &NodeHost{
		ownerUID: ownerUID,
		pkgs:     map[string]*nodePkg{},
		apiIndex: map[string]string{},
	}
}

// nodeHostForUser 指定 RuntimeUserID 的 Node 桶；空串为本机共享。
func nodeHostForUser(userID string) *NodeHost {
	userID = strings.TrimSpace(userID)
	if userID == "" {
		return sharedNodeHost
	}
	userNodeHostsMu.Lock()
	defer userNodeHostsMu.Unlock()
	if h, ok := userNodeHosts[userID]; ok {
		return h
	}
	h := newNodeHost(userID)
	userNodeHosts[userID] = h
	return h
}

// nodeHostForCurrent 当前请求所属 Node 桶。
func nodeHostForCurrent() *NodeHost {
	return nodeHostForUser(hostclient.RuntimeUserID())
}

// DefaultNodeHost 当前请求所属 Node 桶（本机共享或远端用户独立；须在 Bind 之后使用）。
func DefaultNodeHost() *NodeHost {
	return nodeHostForCurrent()
}

// destroyUserNodeHost 销毁指定远端用户的 Node 桶。
func destroyUserNodeHost(userID string) {
	userID = strings.TrimSpace(userID)
	if userID == "" {
		return
	}
	userNodeHostsMu.Lock()
	h := userNodeHosts[userID]
	delete(userNodeHosts, userID)
	userNodeHostsMu.Unlock()
	if h != nil {
		h.ClearAll()
	}
}

// clearSharedNodeHost 清空本机共享 Node 桶（不碰远端用户桶）。
func clearSharedNodeHost() {
	sharedNodeHost.ClearAll()
}

// stopAllNodeHosts 清空共享 + 全部用户桶（Clear / Reset / Shutdown）。
func stopAllNodeHosts() {
	sharedNodeHost.ClearAll()
	userNodeHostsMu.Lock()
	all := make([]*NodeHost, 0, len(userNodeHosts))
	for id, h := range userNodeHosts {
		all = append(all, h)
		delete(userNodeHosts, id)
	}
	userNodeHostsMu.Unlock()
	for _, h := range all {
		h.ClearAll()
	}
}

// snapshotNodeHosts 返回共享桶 + 当前全部用户桶（只读快照）。
func snapshotNodeHosts() []*NodeHost {
	userNodeHostsMu.Lock()
	hosts := make([]*NodeHost, 0, 1+len(userNodeHosts))
	hosts = append(hosts, sharedNodeHost)
	for _, h := range userNodeHosts {
		hosts = append(hosts, h)
	}
	userNodeHostsMu.Unlock()
	return hosts
}

// NodeRootAliasKnown 任一 Node 桶是否登记了该根别名（gate Bind 前探测用）。
func NodeRootAliasKnown(path string) bool {
	for _, h := range snapshotNodeHosts() {
		if h.MatchNodeRootAlias(path) {
			return true
		}
	}
	return false
}

// findNodePkgByLocalPort 按本机端口在所有桶中找包（端口全局唯一）。
func findNodePkgByLocalPort(portStr string) *nodePkg {
	for _, h := range snapshotNodeHosts() {
		h.mu.Lock()
		for _, p := range h.pkgs {
			if p.Port() > 0 && fmt.Sprintf("%d", p.Port()) == portStr {
				h.mu.Unlock()
				return p
			}
		}
		h.mu.Unlock()
	}
	return nil
}

func beginNodeCall(clientID, ownerUID, pkgID string) (context.Context, func()) {
	ctx, cancel := context.WithTimeout(context.Background(), nodeCallTimeout)
	id := nodeCallSeq.Add(1)
	nodeInflightMu.Lock()
	nodeInflightQ[id] = &nodeInflight{
		id: id, clientID: clientID, ownerUID: ownerUID, pkgID: pkgID, cancel: cancel,
	}
	nodeInflightMu.Unlock()
	return ctx, func() {
		cancel()
		nodeInflightMu.Lock()
		delete(nodeInflightQ, id)
		nodeInflightMu.Unlock()
	}
}

// interruptNodeForClient 只取消匹配 Scope 的 Node in-flight，不停源包进程。
// 配置中心等网页仍挂在同一 Node 端口上；软取消若 Stop 会把服务掐死。
// 需要停进程时走 SoftCancelAll / KillUserRuntime / ClearAll。
func interruptNodeForClient(clientID string) {
	nodeInflightMu.Lock()
	for _, g := range nodeInflightQ {
		if clientID == "" || g.clientID == clientID {
			g.cancel()
		}
	}
	nodeInflightMu.Unlock()
}

// MsgPort 引擎本机端口，供 node 回调 /msg。
func (h *NodeHost) MsgPort() int {
	return localproxy.Port()
}

// LoadPackage 下载并启动源包，返回 GET /config 的 JSON 正文。
func (h *NodeHost) LoadPackage(pkgURL string) (string, error) {
	pkgURL = strings.TrimSpace(pkgURL)
	if pkgURL == "" {
		return "", fmt.Errorf("空的 Node 源包地址")
	}
	if _, err := appruntime.RequireNode(); err != nil {
		return "", err
	}
	pkg, err := h.Ensure(pkgURL)
	if err != nil {
		return "", err
	}
	return pkg.FetchConfig()
}

// Ensure 确保源包已下载并有进程在跑。
// 包文件（index.js）按 URL 全局共享；进程与 dataDir 按本桶 ownerUID 隔离。
func (h *NodeHost) Ensure(pkgURL string) (*nodePkg, error) {
	id := nodePkgID(pkgURL)
	h.mu.Lock()
	pkg, ok := h.pkgs[id]
	if !ok {
		// 包体全局共享 cache/node/<id>/（与 jar/py/js 同级）；可写 data 进 UserNodeDataDir。
		dir := filepath.Join(paths.NodeCache(), id)
		dataDir := paths.UserNodeDataDir(h.ownerUID, id)
		migrateLegacyNodeDataDir(h.ownerUID, id, dataDir)
		pkg = &nodePkg{
			id:       id,
			pkgURL:   pkgURL,
			dir:      dir,
			dataDir:  dataDir,
			indexJS:  filepath.Join(dir, "index.js"),
			configJS: filepath.Join(dir, "index.config.js"),
			ownerUID: h.ownerUID,
			host:     h,
			backoff:  nodeRestartBackoff,
		}
		h.pkgs[id] = pkg
	} else {
		pkg.pkgURL = pkgURL
		pkg.host = h
		pkg.ownerUID = h.ownerUID
	}
	h.mu.Unlock()

	// 包体目录（cache/node/<id>/）与可写 dataDir 分开建：清缓存后根目录还在，子目录常被抹掉。
	if err := os.MkdirAll(pkg.dir, 0o755); err != nil {
		return nil, err
	}
	if err := os.MkdirAll(pkg.dataDir, 0o755); err != nil {
		return nil, err
	}
	if err := h.ensureRunner(); err != nil {
		return nil, err
	}
	if err := pkg.download(pkgURL); err != nil {
		return nil, err
	}
	if err := pkg.start(h); err != nil {
		return nil, err
	}
	return pkg, nil
}

func (h *NodeHost) ensureRunner() error {
	h.mu.Lock()
	defer h.mu.Unlock()
	dest := filepath.Join(paths.NodeCache(), "_kotv_noderunner.js")
	cur, _ := os.ReadFile(dest)
	if !bytes.Equal(cur, []byte(nodeRunnerSrc)) {
		if err := writeFileAtomic(dest, []byte(nodeRunnerSrc)); err != nil {
			return err
		}
	}
	h.runner = dest
	return nil
}

// migrateLegacyNodeDataDir 把旧布局迁到 cache/run/…/node/<id>/data（仅当新目录为空）。
func migrateLegacyNodeDataDir(ownerUID, pkgID, dataDir string) {
	if ents, err := os.ReadDir(dataDir); err == nil && len(ents) > 0 {
		return
	}
	// 旧版曾把 data 塞进包体目录旁（现已改到 cache/run/<uid>/node/<pkg>/data）。
	root := paths.CacheRoot()
	var legacy string
	if ownerUID == "" {
		legacy = filepath.Join(root, "node", pkgID, "data")
	} else {
		legacy = filepath.Join(root, "node", "run", ownerUID, pkgID, "data")
	}
	if st, err := os.Stat(legacy); err != nil || !st.IsDir() {
		return
	}
	_ = os.Remove(dataDir) // 空目标，便于 Rename
	_ = os.MkdirAll(filepath.Dir(dataDir), 0o755)
	if err := os.Rename(legacy, dataDir); err != nil {
		log.Printf("node data migrate skip owner=%q pkg=%s: %v", ownerUID, pkgID, err)
		_ = os.MkdirAll(dataDir, 0o755)
	}
}

func nodePkgID(pkgURL string) string {
	u, err := url.Parse(strings.TrimSpace(pkgURL))
	if err == nil {
		u.User = nil
		u.Fragment = ""
		// 统一成 index.js 形态，避免 .md5 与正式地址分成两个包。
		p := strings.ToLower(u.Path)
		if strings.HasSuffix(p, ".md5") {
			u.Path = u.Path[:len(u.Path)-4]
		}
		pkgURL = u.String()
	}
	sum := md5.Sum([]byte(pkgURL))
	return hex.EncodeToString(sum[:])[:12]
}

func (p *nodePkg) download(pkgURL string) error {
	// 包体全局共享：多用户并发 Ensure 合并为一次下载。
	return doOnce("node-pkg:"+p.id, func() error {
		return p.downloadFiles(pkgURL)
	})
}

func (p *nodePkg) downloadFiles(pkgURL string) error {
	base := util.NodePackageBaseURL(pkgURL)
	files := []struct {
		name string
		dest string
	}{
		{"index.js", p.indexJS},
		{"index.config.js", p.configJS},
	}
	for _, f := range files {
		fileURL := strings.TrimRight(base, "/") + "/" + f.name
		md5URL := fileURL + ".md5"
		want, err := fetchNodeText(md5URL, pkgURL)
		if err != nil {
			// index.config.js.md5 可选：没有配置文件时跳过。
			if f.name == "index.config.js" {
				log.Printf("node pkg %s: 无 %s，跳过", p.id, f.name)
				_ = os.Remove(f.dest)
				continue
			}
			return fmt.Errorf("下载 %s.md5 失败: %w", f.name, err)
		}
		want = strings.TrimSpace(strings.ToLower(want))
		if fields := strings.Fields(want); len(fields) > 0 {
			want = fields[0]
		}
		if len(want) != 32 {
			return fmt.Errorf("%s.md5 无效: %q", f.name, want)
		}
		if st, err := os.Stat(f.dest); err == nil && st.Size() > 0 {
			if sum := fileMD5(f.dest); sum == want {
				continue
			}
		}
		body, err := fetchNodeBytes(fileURL, pkgURL)
		if err != nil {
			return fmt.Errorf("下载 %s 失败: %w", f.name, err)
		}
		sum := md5.Sum(body)
		got := hex.EncodeToString(sum[:])
		if got != want {
			return fmt.Errorf("%s md5 不匹配: got %s want %s", f.name, got, want)
		}
		if err := writeFileAtomic(f.dest, body); err != nil {
			return err
		}
	}
	return nil
}

// fetchNodeText/Bytes：仅对原始源包主机带 Basic；跨主机 302 剥 userinfo。
func fetchNodeText(rawURL, authURL string) (string, error) {
	b, err := fetchNodeBytes(rawURL, authURL)
	if err != nil {
		return "", err
	}
	return string(b), nil
}

func fetchNodeBytes(rawURL, authURL string) ([]byte, error) {
	req, err := http.NewRequest(http.MethodGet, rawURL, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("User-Agent", util.OkHttpUA)
	applyNodeAuth(req, authURL)

	client := &http.Client{
		Timeout: 120 * time.Second,
		CheckRedirect: func(req *http.Request, via []*http.Request) error {
			if len(via) >= 10 {
				return errors.New("too many redirects")
			}
			orig := via[0].URL.Hostname()
			if req.URL.Hostname() != orig {
				req.URL.User = nil
				req.Header.Del("Authorization")
			} else {
				applyNodeAuth(req, authURL)
			}
			return nil
		},
	}
	resp, err := client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(io.LimitReader(resp.Body, 64<<20))
	if err != nil {
		return nil, err
	}
	if resp.StatusCode >= 400 {
		return nil, fmt.Errorf("http %d", resp.StatusCode)
	}
	return body, nil
}

func applyNodeAuth(req *http.Request, authURL string) {
	if req == nil || authURL == "" {
		return
	}
	u, err := url.Parse(authURL)
	if err != nil || u.User == nil {
		return
	}
	if req.URL != nil && req.URL.Hostname() != u.Hostname() {
		return
	}
	userInfo := u.User.String()
	if userInfo == "" {
		return
	}
	req.Header.Set("Authorization", util.BasicAuthHeader(userInfo))
}

func (p *nodePkg) start(h *NodeHost) error {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.cmd != nil && p.cmd.Process != nil && p.cmd.ProcessState == nil && p.port > 0 {
		return nil
	}
	return p.startLocked(h)
}

func (p *nodePkg) startLocked(h *NodeHost) error {
	p.stopLocked()
	// stopLocked 会置 stopping；启动失败须清掉，否则后续 Ensure/watch 被当成「正在停」而空转。
	defer func() {
		if p.cmd == nil {
			p.stopping = false
		}
	}()
	nodeBin, err := appruntime.RequireNode()
	if err != nil {
		return err
	}
	freePort, err := pickFreeLocalPort()
	if err != nil {
		return err
	}
	args := []string{h.runner, p.indexJS}
	if st, err := os.Stat(p.configJS); err == nil && st.Size() > 0 {
		args = append(args, p.configJS)
	}
	cmd := exec.Command(nodeBin, args...)
	cmd.Dir = p.dir
	cmd.Env = appruntime.WithNativeLibDirEnv(append(os.Environ(),
		"HOST=127.0.0.1",
		fmt.Sprintf("DEV_HTTP_PORT=%d", freePort),
		"NODE_PATH="+p.dataDir,
		fmt.Sprintf("KOTV_MSG_PORT=%d", h.MsgPort()),
	), nodeBin)
	setChildProcAttrs(cmd)
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return err
	}
	stderr, err := cmd.StderrPipe()
	if err != nil {
		return err
	}
	if err := cmd.Start(); err != nil {
		return err
	}
	p.cmd = cmd
	p.stopping = false

	portCh := make(chan int, 1)
	go func() {
		sc := bufio.NewScanner(stdout)
		for sc.Scan() {
			line := strings.TrimSpace(sc.Text())
			if strings.HasPrefix(line, "NODE_PORT=") {
				var port int
				if _, err := fmt.Sscanf(line, "NODE_PORT=%d", &port); err == nil && port > 0 {
					select {
					case portCh <- port:
					default:
					}
				}
			} else if line != "" {
				log.Printf("[node:%s] %s", p.id, line)
			}
		}
	}()
	go func() {
		sc := bufio.NewScanner(stderr)
		for sc.Scan() {
			if line := strings.TrimSpace(sc.Text()); line != "" {
				log.Printf("[node:%s] %s", p.id, line)
			}
		}
	}()

	ctx, cancel := context.WithTimeout(context.Background(), nodeStartTimeout)
	defer cancel()
	select {
	case port := <-portCh:
		p.port = port
		p.backoff = nodeRestartBackoff
		log.Printf("node pkg %s listening on 127.0.0.1:%d (%s)", p.id, port, util.MaskURLCredentials(p.pkgURL))
		go p.watch(h)
		return nil
	case <-ctx.Done():
		p.stopLocked()
		return fmt.Errorf("等待 NODE_PORT 超时")
	}
}

func (p *nodePkg) watch(h *NodeHost) {
	cmd := p.cmd
	if cmd == nil {
		return
	}
	err := cmd.Wait()
	p.mu.Lock()
	same := p.cmd == cmd
	stopping := p.stopping
	p.mu.Unlock()
	if !same || stopping {
		return
	}
	log.Printf("node pkg %s 进程退出: %v，将重启", p.id, err)
	p.mu.Lock()
	backoff := p.backoff
	if backoff < nodeRestartBackoff {
		backoff = nodeRestartBackoff
	}
	p.backoff = backoff * 2
	if p.backoff > nodeMaxBackoff {
		p.backoff = nodeMaxBackoff
	}
	p.cmd = nil
	p.port = 0
	p.mu.Unlock()
	time.Sleep(backoff)
	p.mu.Lock()
	defer p.mu.Unlock()
	// 休眠期间若已 Stop，或 Ensure/其它路径已拉起新进程，禁止再 startLocked（会先杀掉新进程，Win7 上表现为切站长时间转圈）。
	if p.stopping || p.cmd != nil {
		return
	}
	if err := p.startLocked(h); err != nil {
		log.Printf("node pkg %s 重启失败: %v", p.id, err)
	}
}

func (p *nodePkg) stopLocked() {
	p.stopping = true
	if p.cmd != nil && p.cmd.Process != nil {
		killProcessTree(p.cmd.Process)
	}
	p.cmd = nil
	p.port = 0
}

// Stop 停止单个源包进程。
func (p *nodePkg) Stop() {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.stopLocked()
}

// Stop 按 id 停止。
func (h *NodeHost) Stop(pkgID string) {
	h.mu.Lock()
	pkg := h.pkgs[pkgID]
	h.mu.Unlock()
	if pkg != nil {
		pkg.Stop()
	}
}

// StopAll 停止全部 Node 源包。
func (h *NodeHost) StopAll() {
	h.mu.Lock()
	pkgs := make([]*nodePkg, 0, len(h.pkgs))
	for _, p := range h.pkgs {
		pkgs = append(pkgs, p)
	}
	h.mu.Unlock()
	for _, p := range pkgs {
		p.Stop()
	}
}

// ClearAll 停本桶进程并清空索引（不删全局 cache/node 包体；全量清理由 clearScriptCaches 负责）。
func (h *NodeHost) ClearAll() {
	h.StopAll()
	h.mu.Lock()
	h.pkgs = map[string]*nodePkg{}
	h.apiIndex = map[string]string{}
	h.rootAliases = map[string]struct{}{}
	h.mu.Unlock()
}

// RegisterPackageAPIs 把 /config 里 video.sites 的 api 全部挂到该包。
func (h *NodeHost) RegisterPackageAPIs(pkgID string, configJSON string) {
	var root struct {
		Sites []struct {
			API string `json:"api"`
		} `json:"sites"`
		Video *struct {
			Sites []struct {
				API string `json:"api"`
			} `json:"sites"`
		} `json:"video"`
	}
	if err := json.Unmarshal([]byte(configJSON), &root); err != nil {
		return
	}
	h.mu.Lock()
	defer h.mu.Unlock()
	add := func(api string) {
		api = strings.TrimSpace(api)
		if strings.HasPrefix(api, "/spider/") {
			h.apiIndex[api] = pkgID
		}
	}
	for _, s := range root.Sites {
		add(s.API)
	}
	if root.Video != nil {
		for _, s := range root.Video.Sites {
			add(s.API)
		}
	}
}

// KnowsAPI 该 api 是否已登记为 Node 站。
func (h *NodeHost) KnowsAPI(api string) bool {
	h.mu.Lock()
	defer h.mu.Unlock()
	_, ok := h.apiIndex[strings.TrimSpace(api)]
	return ok
}

// PkgIDForAPI 返回站点对应的源包 id。
func (h *NodeHost) PkgIDForAPI(api string) string {
	h.mu.Lock()
	defer h.mu.Unlock()
	return h.apiIndex[strings.TrimSpace(api)]
}

// GetPkg 按 id 取包。
func (h *NodeHost) GetPkg(id string) *nodePkg {
	h.mu.Lock()
	defer h.mu.Unlock()
	return h.pkgs[id]
}

// ActivePkg 返回任一已起端口的源包；没有则 nil。
// 根别名页内绝对路径 fetch 打引擎根时，用它反代到当前 Node。
func (h *NodeHost) ActivePkg() *nodePkg {
	h.mu.Lock()
	defer h.mu.Unlock()
	var pkg *nodePkg
	for _, p := range h.pkgs {
		if p != nil && p.Port() > 0 {
			pkg = p
		}
	}
	return pkg
}

// RememberNodeRootAlias 登记 OPENWEB 路径首段，供引擎对 /首段/… 反代 ActivePkg。
func (h *NodeHost) RememberNodeRootAlias(seg string) {
	seg = strings.Trim(strings.TrimSpace(seg), "/")
	if i := strings.IndexByte(seg, '/'); i >= 0 {
		seg = seg[:i]
	}
	if seg == "" || reservedNodeRootSegment(seg) {
		return
	}
	h.mu.Lock()
	defer h.mu.Unlock()
	if h.rootAliases == nil {
		h.rootAliases = map[string]struct{}{}
	}
	h.rootAliases[seg] = struct{}{}
}

// RootAliases 当前已登记的根路径首段。
func (h *NodeHost) RootAliases() []string {
	h.mu.Lock()
	defer h.mu.Unlock()
	out := make([]string, 0, len(h.rootAliases))
	for a := range h.rootAliases {
		out = append(out, a)
	}
	return out
}

// MatchNodeRootAlias 请求路径是否落在已登记根别名下。
func (h *NodeHost) MatchNodeRootAlias(path string) bool {
	seg := firstPathSegment(path)
	if seg == "" {
		return false
	}
	h.mu.Lock()
	defer h.mu.Unlock()
	_, ok := h.rootAliases[seg]
	return ok
}

// ProxyRootAlias 把已登记根别名路径原样反代到 ActivePkg；未命中返回 false。
func (h *NodeHost) ProxyRootAlias(w http.ResponseWriter, r *http.Request) bool {
	if !h.MatchNodeRootAlias(r.URL.Path) {
		return false
	}
	pkg := h.ActivePkg()
	if pkg == nil {
		return false
	}
	path := r.URL.Path
	if path == "" {
		path = "/"
	}
	pkg.Proxy(w, r, path)
	return true
}

func firstPathSegment(path string) string {
	path = strings.TrimSpace(path)
	path = strings.TrimPrefix(path, "/")
	if path == "" {
		return ""
	}
	if i := strings.IndexByte(path, '/'); i >= 0 {
		return path[:i]
	}
	return path
}

func reservedNodeRootSegment(seg string) bool {
	switch strings.ToLower(seg) {
	case "api", "node", "proxy", "file", "image", "library", "ui", "health",
		"k", "msg", "action", "media", "device", "upload", "tvbus", "spider",
		"java", "cache", "newFolder", "delFolder", "delFile":
		return true
	}
	return false
}

// ReleaseOther 切站时保留 keepAPI 所属 Node 源包，停掉其它。
// 非 Node api 时停掉全部；Node api 尚未登记进索引时保留当前已起包，避免误杀后冷启卡住。
func (h *NodeHost) ReleaseOther(keepAPI string) {
	keepAPI = strings.TrimSpace(keepAPI)
	keepID := ""
	if IsNodeAPI(keepAPI) {
		keepID = h.PkgIDForAPI(keepAPI)
		if keepID == "" {
			if p := h.ActivePkg(); p != nil {
				keepID = p.id
			}
		}
	}
	h.mu.Lock()
	pkgs := make([]*nodePkg, 0, len(h.pkgs))
	for id, p := range h.pkgs {
		if keepID != "" && id == keepID {
			continue
		}
		pkgs = append(pkgs, p)
	}
	h.mu.Unlock()
	for _, p := range pkgs {
		p.Stop()
	}
}

func (p *nodePkg) baseURL() string {
	p.mu.Lock()
	defer p.mu.Unlock()
	if p.port <= 0 {
		return ""
	}
	return fmt.Sprintf("http://127.0.0.1:%d", p.port)
}

func (p *nodePkg) Port() int {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.port
}

// FetchConfig GET /config。
func (p *nodePkg) FetchConfig() (string, error) {
	base := p.baseURL()
	if base == "" {
		return "", fmt.Errorf("node 未就绪")
	}
	client := &http.Client{Timeout: nodeConfigTimeout}
	resp, err := client.Get(base + "/config")
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	b, err := io.ReadAll(io.LimitReader(resp.Body, 8<<20))
	if err != nil {
		return "", err
	}
	if resp.StatusCode >= 400 {
		return "", fmt.Errorf("GET /config http %d", resp.StatusCode)
	}
	h := p.host
	if h == nil {
		h = nodeHostForCurrent()
	}
	h.RegisterPackageAPIs(p.id, string(b))
	return string(b), nil
}

// PostJSON POST 路径，返回响应正文。可被 SoftCancel 取消；超时或取消后 Stop 本源包进程。
func (p *nodePkg) PostJSON(path string, body any) (string, error) {
	base := p.baseURL()
	if base == "" {
		return "", fmt.Errorf("node 未就绪")
	}
	payload, err := json.Marshal(body)
	if err != nil {
		return "", err
	}
	ctx, end := beginNodeCall(hostclient.ScopeID(), p.ownerUID, p.id)
	defer end()
	req, err := http.NewRequestWithContext(ctx, http.MethodPost, base+path, bytes.NewReader(payload))
	if err != nil {
		return "", err
	}
	req.Header.Set("Content-Type", "application/json; charset=utf-8")
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		// 超时才停进程（防挂死）；软取消只返回 Interrupted，保留源包（配置页等仍用同一端口）。
		if errors.Is(err, context.DeadlineExceeded) {
			p.Stop()
			return "", fmt.Errorf("node 调用超过 %s", nodeCallTimeout)
		}
		if errors.Is(err, context.Canceled) {
			return "", ErrNodeInterrupted
		}
		return "", err
	}
	defer resp.Body.Close()
	b, err := io.ReadAll(io.LimitReader(resp.Body, 16<<20))
	if err != nil {
		return "", err
	}
	if resp.StatusCode >= 400 {
		return "", fmt.Errorf("POST %s http %d: %s", path, resp.StatusCode, truncatePyLog(string(b)))
	}
	out := strings.TrimSpace(string(b))
	if out == "" {
		return "{}", nil
	}
	return out, nil
}

// Proxy 反代到 node 进程。path 为去掉 /node/<pkg> 后的路径。
func (p *nodePkg) Proxy(w http.ResponseWriter, r *http.Request, path string) {
	base := p.baseURL()
	if base == "" {
		http.Error(w, "node 未就绪", http.StatusBadGateway)
		return
	}
	target, err := url.Parse(base)
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadGateway)
		return
	}
	proxy := httputil.NewSingleHostReverseProxy(target)
	proxy.ErrorHandler = func(rw http.ResponseWriter, _ *http.Request, err error) {
		log.Printf("node proxy %s: %v", p.id, err)
		http.Error(rw, "node 反代失败", http.StatusBadGateway)
	}
	orig := r.URL.Path
	r.URL.Path = path
	if r.URL.RawPath != "" {
		r.URL.RawPath = path
	}
	r.Host = target.Host
	proxy.ServeHTTP(w, r)
	r.URL.Path = orig
}

var (
	reLocalNodeURL = regexp.MustCompile(`(?i)https?://(?:127\.0\.0\.1|localhost):(\d+)`)
	// 带可选 path/query/fragment，统一改写到 /node/<pkg>/…。
	reLocalNodeURLParts = regexp.MustCompile(`(?i)https?://(?:127\.0\.0\.1|localhost):(\d+)((?:/[^?\s"'\\]*)?(?:\?[^#\s"'\\]*)?(?:#[^\s"'\\]*)?)`)
	reJS2P              = regexp.MustCompile(`(?i)js2p://_WEB_`)
)

// nodeProxyBase 本包在引擎上的 /node/<pkg> 根。
// PublicBase 空时为 127.0.0.1；远端则为客户端可达根（含媒体钥匙路径）。
func (p *nodePkg) nodeProxyBase() string {
	loop := fmt.Sprintf("http://127.0.0.1:%d/node/%s", localproxy.Port(), p.id)
	return playproxy.PublicizeURL(loop)
}

// rewriteToNodeProxy 播放/弹幕：本包回环与 js2p://_WEB_ → /node/<pkg>/…。
func (p *nodePkg) rewriteToNodeProxy(raw string) string {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return raw
	}
	nodeBase := p.nodeProxyBase()
	port := p.Port()
	if port > 0 {
		ps := fmt.Sprintf("%d", port)
		raw = reLocalNodeURLParts.ReplaceAllStringFunc(raw, func(m string) string {
			sub := reLocalNodeURLParts.FindStringSubmatch(m)
			if len(sub) < 2 || sub[1] != ps {
				return m
			}
			rest := ""
			if len(sub) > 2 {
				rest = sub[2]
			}
			if rest == "" {
				return strings.TrimRight(nodeBase, "/")
			}
			return strings.TrimRight(nodeBase, "/") + rest
		})
	}
	return reJS2P.ReplaceAllString(raw, nodeBase)
}

// RewritePlayJSON 播放 JSON：本机 node 地址与 js2p://_WEB_ → 引擎可达地址。
func (p *nodePkg) RewritePlayJSON(raw string) string {
	return p.rewriteToNodeProxy(raw)
}

// RewriteNodeURL 单条 URL（弹幕等）→ /node/<pkg>/…。
func (p *nodePkg) RewriteNodeURL(raw string) string {
	return p.rewriteToNodeProxy(strings.TrimSpace(raw))
}

// profilePath 源包 profile.json。
func (p *nodePkg) profilePath() string {
	return filepath.Join(p.dataDir, "profile.json")
}

func (p *nodePkg) queryProfile() any {
	b, err := os.ReadFile(p.profilePath())
	if err != nil || len(b) == 0 {
		return nil
	}
	var v any
	if err := json.Unmarshal(b, &v); err != nil {
		return nil
	}
	return v
}

func (p *nodePkg) saveProfile(profile any) error {
	b, err := json.Marshal(profile)
	if err != nil {
		return err
	}
	return writeFileAtomic(p.profilePath(), b)
}