package server

import (
	"io/fs"
	"net/http"

	"github.com/bobo/KOTV/internal/playproxy"
	"github.com/bobo/KOTV/internal/smbproxy"
	"github.com/bobo/KOTV/internal/thunder"
)

// need 远端访问一条路由的要求。本机直连一律放行（见 gate）。
type need int

const (
	needUser   need = iota // 已登录用户；媒体地址（playproxy.IsMediaPath）也可凭媒体钥匙只读
	needPublic             // 不登录也能访问
	needAdmin              // 管理员
	needLocal              // 只限本机
)

type route struct {
	pattern string
	need    need
	handler http.HandlerFunc
}

// routes 引擎自己处理的全部 HTTP 路由（静态页面见 webRoutes）。
func (s *Server) routes() []route {
	return []route{
		// 探测与登录
		{"/health", needPublic, s.handleHealth},
		{"/api/v1/health", needPublic, s.handleAPIv1Health},
		{"/api/v1/net", needPublic, s.handleAPIv1Net},
		{"/api/v1/auth/status", needPublic, s.handleAuthStatus},
		{"/api/v1/auth/login", needPublic, s.handleAuthLogin},
		{"/api/v1/auth/register", needPublic, s.handleAuthRegister},
		{"/api/v1/auth/logout", needUser, s.handleAuthLogout},
		{"/api/v1/auth/me", needUser, s.handleAuthMe},
		{"/api/v1/auth/password", needUser, s.handleAuthPassword},

		// 用户管理与主机
		{"/api/v1/admin/users", needAdmin, s.handleAdminUsers},
		{"/api/v1/admin/users/", needAdmin, s.handleAdminUserAction},
		{"/api/v1/admin/settings", needAdmin, s.handleAdminSettings},
		{"/api/v1/admin/console-settings", needAdmin, s.handleAdminConsoleSettings},
		{"/api/v1/admin/groups", needAdmin, s.handleAdminGroups},
		{"/api/v1/admin/groups/", needAdmin, s.handleAdminGroupAction},
		{"/api/v1/admin/notices", needAdmin, s.handleAdminNotices},
		{"/api/v1/admin/push/open", needAdmin, s.handleAdminPushOpen},
		{"/api/v1/admin/push/logs", needAdmin, s.handleAdminPushLogs},
		{"/api/v1/admin/stats", needAdmin, s.handleAdminStats},
		{"/api/v1/admin/stats/", needAdmin, s.handleAdminStats},
		{"/api/v1/admin/invites", needAdmin, s.handleAdminInvites},
		{"/api/v1/admin/audit", needAdmin, s.handleAdminAudit},
		{"/api/v1/admin/sessions", needAdmin, s.handleAdminSessions},
		{"/api/v1/admin/logs", needAdmin, s.handleAdminLogs},
		{"/api/v1/admin/ops/", needAdmin, s.handleAdminOps},
		{"/api/v1/fs", needAdmin, s.handleAPIv1Fs},
		{"/api/v1/shutdown", needLocal, s.handleAPIv1Shutdown},

		// App 内容
		{"/api/v1/notice/ack", needUser, s.handleNoticeAck},
		{"/api/v1/session/ping", needUser, s.handleSessionPing},
		{"/api/v1/session/leave", needUser, s.handleSessionLeave},
		{"/api/v1/config", needUser, s.handleAPIv1Config},
		{"/api/v1/config/refresh", needUser, s.handleAPIv1ConfigRefresh},
		{"/api/v1/home", needUser, s.handleAPIv1Home},
		{"/api/v1/category", needUser, s.handleAPIv1Category},
		{"/api/v1/action", needUser, s.handleAPIv1Action},
		{"/api/v1/detail", needUser, s.handleAPIv1Detail},
		{"/api/v1/detail/expand", needUser, s.handleAPIv1DetailExpand},
		{"/api/v1/bt/progress", needUser, s.handleAPIv1BtProgress},
		{"/api/v1/search", needUser, s.handleAPIv1Search},
		{"/api/v1/play", needUser, s.handleAPIv1Play},
		{"/api/v1/danmaku", needUser, s.handleAPIv1Danmaku},
		{"/api/v1/sites", needUser, s.handleAPIv1Sites},
		{"/api/v1/remote/poll", needUser, s.handleAPIv1RemotePoll},
		{"/api/v1/media", needUser, s.handleAPIv1Media},
		{"/api/v1/repos", needUser, s.handleAPIv1Repos},
		{"/api/v1/settings", needUser, s.handleAPIv1Settings},
		{"/api/v1/live", needUser, s.handleAPIv1Live},
		{"/api/v1/player", needUser, s.handleAPIv1Player},
		{"/api/v1/tools", needUser, s.handleAPIv1Tools},
		{"/api/v1/cancel", needUser, s.handleAPIv1Cancel},
		{"/api/v1/download", needUser, s.handleAPIv1Download},
		{"/library", needUser, s.handleLibrary},
		{"/ui", needUser, s.handleUI},

		// 媒体：播放器、图片加载直接请求
		{"/proxy", needUser, s.handleSpiderProxy},
		{"/proxy/play", needUser, playproxy.Handle},
		{"/proxy/bt/", needUser, thunder.Handle},
		{"/proxy/smb/", needUser, smbproxy.Handle},
		{"/file", needUser, s.handleFile},
		{"/file/", needUser, s.handleFile},
		{"/image/", needUser, s.handleImage},
		{"/tvbus", needUser, s.handleTvbus},
		// 猫爪 Node：/node/msg 仅本机；/node/<pkg>/… 反代到源包。
		// 页内绝对路径根别名（如源包自挂 /website）由 gate 动态反代，不在此硬编码。
		{"/node/msg", needLocal, s.handleNodeMsg},
		{"/msg", needLocal, s.handleNodeMsg}, // CatPawOpen messageToDart 固定打 /msg
		{"/node/", needUser, s.handleNodeProxy},

		// 设备之间、遥控页、爬虫运行时
		{"/action", needAdmin, s.handleAction},
		{"/media", needAdmin, s.handleMedia},
		{"/device", needAdmin, s.handleDevice},
		{"/upload", needAdmin, s.handleUpload},
		{"/newFolder", needAdmin, s.handleNewFolder},
		{"/delFolder", needAdmin, s.handleDelPath},
		{"/delFile", needAdmin, s.handleDelPath},
		{"/cache", needAdmin, s.handleCache},
		{"/java", needAdmin, s.handleJavaInvoke},
		{"/parse", needAdmin, s.handleParsePage},
	}
}

// buildMux 注册全部路由，记下每条的远端访问要求（gate 用），并告诉 playproxy 哪些路径归引擎处理。
func (s *Server) buildMux(remote fs.FS) *http.ServeMux {
	mux := http.NewServeMux()
	needs := map[string]need{}
	engine := s.routes()
	patterns := make([]string, 0, len(engine))
	for _, rt := range engine {
		patterns = append(patterns, rt.pattern)
	}
	for _, rt := range append(engine, webRoutes(remote)...) {
		mux.HandleFunc(rt.pattern, rt.handler)
		needs[rt.pattern] = rt.need
	}
	playproxy.SetEngineRoutes(patterns)
	s.mu.Lock()
	s.mux, s.needs = mux, needs
	s.mu.Unlock()
	return mux
}

// routeNeed 请求命中的路由的远端访问要求。
func (s *Server) routeNeed(r *http.Request) need {
	s.mu.RLock()
	mux, needs := s.mux, s.needs
	s.mu.RUnlock()
	if mux == nil {
		return needUser
	}
	_, pattern := mux.Handler(r)
	return needs[pattern]
}
