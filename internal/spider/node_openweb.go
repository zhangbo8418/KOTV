package spider

import (
	"fmt"
	"net/url"
	"strings"
	"sync"

	"github.com/bobo/KOTV/internal/hostclient"
	"github.com/bobo/KOTV/internal/localproxy"
	"github.com/bobo/KOTV/internal/playproxy"
)

// detailOpenWeb：本会话详情过程中是否已 emit OPENWEB（按 Scope 记，供详情 API 同步带回）。
var detailOpenWeb sync.Map // scope -> struct{}

func noteDetailOpenWeb(scope string) {
	scope = strings.TrimSpace(scope)
	if scope == "" {
		scope = "_"
	}
	detailOpenWeb.Store(scope, struct{}{})
}

// TakeDetailOpenWeb 取出并清除本会话的「详情已开网页」标记。
func TakeDetailOpenWeb(scope string) bool {
	scope = strings.TrimSpace(scope)
	if scope == "" {
		scope = "_"
	}
	_, ok := detailOpenWeb.LoadAndDelete(scope)
	return ok
}

// callerSnap 最近一次引擎→Node 调用方会话，供本机 /msg 的 OPENWEB 恢复 Bind。
type callerSnap struct {
	ClientID   string
	UserID     string
	Username   string
	Scope      string
	PublicBase string
	AuthToken  string
	Dedicated  bool
	Platform   string
}

func (c callerSnap) empty() bool {
	return c.Scope == "" && c.PublicBase == "" && c.AuthToken == "" && c.ClientID == "" && c.UserID == ""
}

func (c callerSnap) bindRequest() hostclient.Request {
	return hostclient.Request{
		ClientID:   c.ClientID,
		UserID:     c.UserID,
		Username:   c.Username,
		Dedicated:  c.Dedicated,
		Platform:   c.Platform,
		PublicBase: c.PublicBase,
		AuthToken:  c.AuthToken,
	}
}

// rememberCaller 在引擎→Node 调用时戳记当前会话。
func (p *nodePkg) rememberCaller() {
	if p == nil {
		return
	}
	req := hostclient.Snapshot()
	snap := callerSnap{
		ClientID:   req.ClientID,
		UserID:     req.UserID,
		Username:   req.Username,
		Scope:      hostclient.ScopeID(),
		PublicBase: req.PublicBase,
		AuthToken:  req.AuthToken,
		Dedicated:  req.Dedicated,
		Platform:   req.Platform,
	}
	if snap.empty() {
		return
	}
	p.mu.Lock()
	p.caller = snap
	p.mu.Unlock()
}

func (p *nodePkg) takeCaller() callerSnap {
	if p == nil {
		return callerSnap{}
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.caller
}

// resolveNodePkgForURL prefix → URL 本机端口 → 任一就绪包。
func resolveNodePkgForURL(raw, prefix string) *nodePkg {
	var pkg *nodePkg
	if strings.TrimSpace(prefix) != "" {
		pkg = resolveNodePkg(prefix)
	}
	if pkg == nil {
		pkg = resolveNodePkgByLocalPort(raw)
	}
	if pkg == nil {
		pkg = resolveNodePkg("")
	}
	return pkg
}

// rewriteNodePkgURL 弹幕等：选包后 RewriteNodeURL；无包则尽量 Publicize。
func rewriteNodePkgURL(u, prefix string) string {
	u = strings.TrimSpace(u)
	if u == "" {
		return u
	}
	if pkg := resolveNodePkgForURL(u, prefix); pkg != nil {
		return pkg.RewriteNodeURL(u)
	}
	return playproxy.PublicizeURL(u)
}

// emitOpenWeb 恢复调用方会话、改写 URL，并定向投递 OPENWEB。
func emitOpenWeb(raw, prefix string) {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return
	}
	pkg := resolveNodePkgForURL(raw, prefix)
	scope := ""
	if pkg != nil {
		if snap := pkg.takeCaller(); !snap.empty() {
			defer hostclient.Bind(snap.bindRequest())()
			scope = snap.Scope
		}
		raw = pkg.RewriteOpenWebURL(raw)
	} else {
		raw = playproxy.PublicizeURL(raw)
	}
	if raw != "" {
		jsPostMsg("OPENWEB:"+raw, scope)
		noteDetailOpenWeb(scope)
	}
}

// RewriteOpenWebURL 仅 OPENWEB：本机原样；远端 → /node/<pkg>/…（无媒体钥匙）+ 可选 ?token=。
// 同时登记路径首段为根别名，供页内绝对路径 API 反代。
func (p *nodePkg) RewriteOpenWebURL(raw string) string {
	raw = strings.TrimSpace(raw)
	if raw == "" || p == nil {
		return raw
	}
	u, err := url.Parse(raw)
	if err != nil || u.Host == "" {
		return raw
	}
	host := strings.ToLower(u.Hostname())
	if host != "127.0.0.1" && host != "localhost" && host != "::1" {
		if hostclient.PublicBase() != "" {
			return appendQueryToken(playproxy.PublicizeURL(raw), hostclient.AuthToken())
		}
		return raw
	}
	port := u.Port()
	if port == "" {
		if strings.EqualFold(u.Scheme, "https") {
			port = "443"
		} else {
			port = "80"
		}
	}
	if fmt.Sprintf("%d", p.Port()) != port {
		return raw
	}
	path := u.EscapedPath()
	if path == "" {
		path = "/"
	}
	if seg := firstPathSegment(path); seg != "" {
		h := p.host
		if h == nil {
			h = nodeHostForCurrent()
		}
		h.RememberNodeRootAlias(seg)
	}
	if hostclient.PublicBase() == "" {
		return raw
	}
	engine := fmt.Sprintf("http://127.0.0.1:%d/node/%s%s", localproxy.Port(), p.id, path)
	if u.RawQuery != "" {
		engine += "?" + u.RawQuery
	}
	if u.Fragment != "" {
		engine += "#" + u.Fragment
	}
	return appendQueryToken(publicizeOpenWebPage(engine), hostclient.AuthToken())
}

// publicizeOpenWebPage 客户端可达根，且去掉 PublicBase 中的媒体钥匙（浏览器页走用户 token）。
func publicizeOpenWebPage(engineURL string) string {
	snap := hostclient.Snapshot()
	if snap.PublicBase == "" {
		return engineURL
	}
	snap.PublicBase = stripPublicMediaKey(snap.PublicBase)
	defer hostclient.Bind(snap)()
	return playproxy.PublicizeURL(engineURL)
}

func stripPublicMediaKey(base string) string {
	base = strings.TrimSpace(base)
	u, err := url.Parse(base)
	if err != nil || u.Host == "" {
		return strings.TrimRight(base, "/")
	}
	if !strings.HasPrefix(u.Path, playproxy.MediaKeyPrefix) {
		return strings.TrimRight(base, "/")
	}
	rest := strings.TrimPrefix(u.Path, playproxy.MediaKeyPrefix)
	if i := strings.IndexByte(rest, '/'); i >= 0 {
		u.Path = rest[i:]
	} else {
		u.Path = ""
	}
	u.RawPath = ""
	return strings.TrimRight(u.String(), "/")
}

func appendQueryToken(raw, token string) string {
	token = strings.TrimSpace(token)
	if token == "" {
		return raw
	}
	u, err := url.Parse(raw)
	if err != nil || u.Host == "" {
		return raw
	}
	q := u.Query()
	if strings.TrimSpace(q.Get("token")) != "" {
		return raw
	}
	q.Set("token", token)
	u.RawQuery = q.Encode()
	return u.String()
}
