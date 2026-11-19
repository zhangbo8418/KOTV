package server

import (
	"context"
	"net"
	"net/http"
	"net/url"
	"strconv"
	"strings"

	"github.com/bobo/KOTV/internal/auth"
	"github.com/bobo/KOTV/internal/hostclient"
	"github.com/bobo/KOTV/internal/playproxy"
	"github.com/bobo/KOTV/internal/spider"
	"github.com/bobo/KOTV/internal/util"
)

// ProtocolVersion 前后端接口协议号，接口或加密方式不兼容时加一。
// 远端客户端在请求头 X-Kotv-Protocol 带上自己的协议号，不一致的接口请求一律拒绝；
// 健康检查不拦，客户端据其中的 protocol 提示升级。
const ProtocolVersion = 1

// access 请求能访问的范围，由 gate 写入请求上下文。
type access int

const (
	accessPublic access = iota // 只能访问公开内容（健康检查、登录、静态页面）
	accessMedia                // 凭媒体钥匙只读媒体地址
	accessFull                 // 本机，或已登录的远端用户
)

type ctxKey int

const (
	authUserKey ctxKey = iota
	accessKey
)

func authUserFrom(ctx context.Context) *auth.User {
	u, _ := ctx.Value(authUserKey).(*auth.User)
	return u
}

func requestAccess(r *http.Request) access {
	a, _ := r.Context().Value(accessKey).(access)
	return a
}

// gate 所有 HTTP 请求的统一入口：判定能否访问，再把身份、平台、对外根地址绑定到本次请求。
// 每条路由的远端访问要求见 routes.go。
//
//   - 本机直连免登录（Web 页面除外，它总要登录）。
//   - needPublic：不登录也能访问。
//   - 媒体钥匙（/k/<钥匙>/…）：只读访问媒体地址，给播放器、图片加载、电视投屏用。
//   - 其余远端请求：主机须开启远端鉴权，并带有效登录令牌；needAdmin 还须是管理员，needLocal 一律拒绝。
func (s *Server) gate(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		mediaKey := ""
		if key, rest, ok := playproxy.SplitMediaKey(r.URL.Path); ok {
			mediaKey = key
			r = r.Clone(r.Context())
			r.URL.Path, r.URL.RawPath = rest, ""
		}
		if protocolMismatch(r) {
			writeAPIError(w, http.StatusUpgradeRequired, "客户端与后端版本不匹配，请升级到相同版本")
			return
		}
		local := isLocalNative(r)
		need := s.routeNeed(r)
		rootAlias := spider.NodeRootAliasKnown(r.URL.Path)
		if rootAlias {
			need = needUser
		}
		token := requestToken(r)
		var user *auth.User
		if token != "" {
			user, _ = auth.LookupToken(token)
		}

		level := accessFull
		switch {
		case local:
		case need == needLocal:
			writeAPIError(w, http.StatusForbidden, "只允许本机访问")
			return
		// 登录令牌优先于媒体钥匙，便于 /node/…?token= 按用户会话放行并种根别名 Cookie。
		case user != nil && remoteAccessAllowed(r):
		case mediaKey != "":
			if !auth.ValidMediaKey(mediaKey) {
				writeAPIError(w, http.StatusUnauthorized, "媒体地址已过期，请重新打开")
				return
			}
			if !playproxy.IsMediaPath(r.URL.Path) || (r.Method != http.MethodGet && r.Method != http.MethodHead) {
				writeAPIError(w, http.StatusForbidden, "媒体钥匙只能读取媒体")
				return
			}
			level = accessMedia
		case need == needPublic:
			level = accessPublic
		case !remoteAccessAllowed(r):
			// 管理面（needAdmin：遥控写操作、/admin API）：即使未开远端鉴权，也允许走「登录→管理员」校验。
			// 普通内容面仍拒绝，避免局域网在关闭远端鉴权时裸奔。
			if need != needAdmin {
				writeAPIError(w, http.StatusForbidden, "未开启远端鉴权")
				return
			}
			if token != "" && user == nil {
				writeAPIError(w, http.StatusUnauthorized, "登录已失效")
				return
			}
			if user == nil {
				writeAPIError(w, http.StatusUnauthorized, "需要登录")
				return
			}
		case token != "":
			writeAPIError(w, http.StatusUnauthorized, "登录已失效")
			return
		default:
			writeAPIError(w, http.StatusUnauthorized, "需要登录")
			return
		}
		if level == accessFull && need == needAdmin && !isAdmin(r, user) {
			writeAPIError(w, http.StatusForbidden, "需要管理员")
			return
		}

		bind := hostclient.Request{Platform: requestPlatform(r), AuthToken: token}
		if user != nil && !local {
			bind.UserID, bind.Username, bind.Dedicated = user.ID, user.Username, true
		} else {
			bind.ClientID = clientIDFromRequest(r)
		}
		if !local {
			// 远端拿到的媒体地址都带媒体钥匙：沿用请求自带的，已登录的签发当前的。
			bind.PublicBase = requestPublicBase(r)
			if mediaKey == "" && level == accessFull {
				mediaKey = auth.MediaKey()
			}
			if bind.PublicBase != "" && mediaKey != "" {
				bind.PublicBase += playproxy.MediaKeyPrefix + mediaKey
			}
		}
		defer hostclient.Bind(bind)()

		if user != nil {
			w = wrapNodeRootAuthCookies(w, r, token)
		}

		ctx := context.WithValue(r.Context(), accessKey, level)
		if user != nil {
			ctx = context.WithValue(ctx, authUserKey, user)
		}
		r = r.WithContext(ctx)

		// 分组策略闸门（维护/IP/时段/账号状态）；admin 与本机豁免。
		if level == accessFull && need == needUser && enforceGroupPolicy(w, r) {
			return
		}

		// OPENWEB 登记的根别名：反代 ActivePkg（不硬编码业务路径名）。
		if rootAlias {
			stripQueryToken(r)
			if spider.DefaultNodeHost().ProxyRootAlias(w, r) {
				return
			}
			http.Error(w, "Node 源包未就绪", http.StatusBadGateway)
			return
		}
		next.ServeHTTP(w, r)
	})
}

// isLocalNative 本机且非 Flutter Web。
// 静态遥控/管理页不带 platform=web，本机免登；Flutter Web 带 platform=web，即使 127.0.0.1 也要登录。
func isLocalNative(r *http.Request) bool {
	return isLoopbackRequest(r) && !isWebClient(r)
}

// isAdmin 本机静态/原生免登管理，或已登录的管理员。Flutter Web 必须管理员令牌。
func isAdmin(r *http.Request, user *auth.User) bool {
	if isLocalNative(r) {
		return true
	}
	return user != nil && user.Role == auth.RoleAdmin
}

// rejectUnlessAdmin 共享仓/直播列表删改用；非管理员写 403 并返回 true。
func rejectUnlessAdmin(w http.ResponseWriter, r *http.Request) bool {
	if isAdmin(r, authUserFrom(r.Context())) {
		return false
	}
	writeAPIError(w, http.StatusForbidden, "需要管理员")
	return true
}

// protocolMismatch 非本机原生的 /api/v1 请求协议号与后端不一致。
func protocolMismatch(r *http.Request) bool {
	if isLocalNative(r) || !strings.HasPrefix(r.URL.Path, "/api/v1/") || r.URL.Path == "/api/v1/health" {
		return false
	}
	return strings.TrimSpace(r.Header.Get("X-Kotv-Protocol")) != strconv.Itoa(ProtocolVersion)
}

// isLoopbackRequest 本机直连。经反代转发的请求（带转发头）即使来自回环也按远端处理，
// 否则在主机上配反代会让所有远端请求都免登录。
func isLoopbackRequest(r *http.Request) bool {
	for _, h := range []string{"Forwarded", "X-Forwarded-For", "X-Forwarded-Host", "X-Real-IP"} {
		if r.Header.Get(h) != "" {
			return false
		}
	}
	host, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		host = r.RemoteAddr
	}
	ip := net.ParseIP(host)
	return ip != nil && ip.IsLoopback()
}

// remoteAccessAllowed 是否允许该客户端连入（再谈是否要登录）。
//   - 本机：始终允许。
//   - Flutter Web（X-Kotv-Client-Platform: web）：始终允许，但必须登录。
//   - 其它远端：主机须开启远端鉴权。
func remoteAccessAllowed(r *http.Request) bool {
	return isLoopbackRequest(r) || isWebClient(r) || auth.RemoteAuthEnabled()
}

// loginRequired 该客户端是否必须登录。
//   - Flutter Web：始终要（含本机浏览器打开的 Flutter Web）。
//   - 静态遥控/管理页不带 platform=web：本机不要，远端随 remoteAuth。
func loginRequired(r *http.Request) bool {
	if isWebClient(r) {
		return true
	}
	return auth.RemoteAuthEnabled() && !isLoopbackRequest(r)
}

func isWebClient(r *http.Request) bool {
	return requestPlatform(r) == "web"
}

// requestPlatform 前端平台。界面套接字 /ui 带不了请求头，放在网址参数里。
func requestPlatform(r *http.Request) string {
	plat := r.Header.Get("X-Kotv-Client-Platform")
	if plat == "" && r.URL.Path == "/ui" {
		plat = r.URL.Query().Get("platform")
	}
	return strings.ToLower(strings.TrimSpace(plat))
}

// clientLabel 请求方客户端「平台 架构 版本」，记日志用。
func clientLabel(r *http.Request) string {
	h := r.Header
	return strings.Join(strings.Fields(strings.Join([]string{
		h.Get("X-Kotv-Client-Platform"), h.Get("X-Kotv-Client-Arch"), h.Get("X-Kotv-Client-Version"),
	}, " ")), " ")
}

// requestPublicBase 优先用前端填写的连接根；没有则用请求 Host 或反代转发头。
// 回环主机不改写，本机播放继续用 127.0.0.1。
func requestPublicBase(r *http.Request) string {
	if b := clientEngineBase(r.Header.Get("X-Kotv-Engine-Base")); b != "" {
		return b
	}
	host := strings.TrimSpace(r.Header.Get("X-Forwarded-Host"))
	if host != "" {
		host = strings.TrimSpace(strings.Split(host, ",")[0])
	}
	if host == "" {
		host = strings.TrimSpace(r.Host)
	}
	if host == "" {
		return ""
	}
	hostname := host
	if h, _, err := net.SplitHostPort(host); err == nil {
		hostname = h
	}
	if util.IsLoopbackHost(hostname) {
		return ""
	}
	scheme := "http"
	if r.TLS != nil {
		scheme = "https"
	}
	if xf := strings.TrimSpace(r.Header.Get("X-Forwarded-Proto")); xf != "" {
		scheme = strings.ToLower(strings.TrimSpace(strings.Split(xf, ",")[0]))
	}
	return scheme + "://" + host
}

func clientEngineBase(raw string) string {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return ""
	}
	u, err := url.Parse(raw)
	if err != nil || (u.Scheme != "http" && u.Scheme != "https") || u.Host == "" {
		return ""
	}
	if util.IsLoopbackHost(u.Hostname()) {
		return ""
	}
	return u.Scheme + "://" + u.Host
}
