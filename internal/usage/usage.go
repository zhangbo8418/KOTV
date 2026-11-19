package usage

import (
	"net/http"
	"strings"
	"sync"
	"time"

	"github.com/bobo/KOTV/internal/auth"
	"github.com/bobo/KOTV/internal/database"
	"github.com/bobo/KOTV/internal/grouppolicy"
	"github.com/bobo/KOTV/internal/settings"
)

var (
	mu    sync.Mutex
	store *database.DB
)

func BindDB(db *database.DB) { store = db }

// Context 从请求提取上报字段。
type Context struct {
	UserID   string
	GroupID  string
	ClientID string
	Platform string
	Arch     string
	AppVer   string
	Protocol string
	IP       string
}

func FromRequest(r *http.Request, user *auth.User) Context {
	c := Context{
		ClientID: strings.TrimSpace(r.Header.Get("X-Kotv-Client-Id")),
		Platform: strings.TrimSpace(r.Header.Get("X-Kotv-Client-Platform")),
		Arch:     strings.TrimSpace(r.Header.Get("X-Kotv-Client-Arch")),
		AppVer:   strings.TrimSpace(r.Header.Get("X-Kotv-Client-Version")),
		Protocol: strings.TrimSpace(r.Header.Get("X-Kotv-Protocol")),
		IP:       strings.TrimSpace(r.RemoteAddr),
	}
	if i := strings.LastIndex(c.IP, ":"); i > 0 {
		// 粗略去掉端口
		if !strings.Contains(c.IP, "]") {
			c.IP = c.IP[:i]
		}
	}
	if user != nil {
		c.UserID = user.ID
		c.GroupID = user.GroupID
		if c.GroupID == "" {
			c.GroupID = database.DefaultGroupID
		}
	} else {
		c.GroupID = database.DefaultGroupID
	}
	return c
}

func Record(ctx Context, kind, refType, refID, refName string, ok bool, errCode string, latencyMs int64) {
	d := store
	if d == nil || kind == "" {
		return
	}
	_ = d.InsertUsageEvent(database.UsageEvent{
		At:       time.Now().UnixMilli(),
		UserID:   ctx.UserID,
		GroupID:  ctx.GroupID,
		ClientID: ctx.ClientID,
		Platform: ctx.Platform,
		Arch:     ctx.Arch,
		AppVer:   ctx.AppVer,
		Protocol: ctx.Protocol,
		IP:       ctx.IP,
		Kind:     kind,
		RefType:  refType,
		RefID:    refID,
		RefName:  refName,
		OK:       ok,
		ErrCode:  errCode,
		Latency:  latencyMs,
	})
}

func RecordLogin(username, userID string, ok bool, r *http.Request) {
	plat := ""
	ip := ""
	if r != nil {
		plat = strings.TrimSpace(r.Header.Get("X-Kotv-Client-Platform"))
		ip = strings.TrimSpace(r.RemoteAddr)
	}
	if d := store; d != nil {
		_ = d.InsertLoginLog(username, userID, ok, ip, plat)
	}
	ctx := Context{UserID: userID, GroupID: database.DefaultGroupID, Platform: plat, IP: ip}
	if u := auth.GetUser(userID); u != nil {
		ctx.GroupID = u.GroupID
	}
	Record(ctx, "login", "user", userID, username, ok, "", 0)
}

func TouchDevice(user *auth.User, r *http.Request) {
	if user == nil || store == nil || r == nil {
		return
	}
	cid := strings.TrimSpace(r.Header.Get("X-Kotv-Client-Id"))
	if cid == "" {
		return
	}
	name := strings.TrimSpace(r.Header.Get("X-Kotv-Client-Platform"))
	_ = store.UpsertAuthDevice(user.ID, cid, name)
}

// OnlineHint 供概览：最近 N 分钟有 ping 的去重（从 usage_event 粗算）。
func OnlineSince(ms int64) (users int, err error) {
	if store == nil {
		return 0, nil
	}
	from := time.Now().UnixMilli() - ms
	sum, err := store.StatsSummary(from, time.Now().UnixMilli(), "", "")
	if err != nil {
		return 0, err
	}
	if v, ok := sum["dau"].(int); ok {
		return v, nil
	}
	return 0, nil
}

// PolicyFor 便捷。
func PolicyFor(user *auth.User) grouppolicy.Bundle {
	return grouppolicy.Resolve(user)
}

// SearchTermsEnabled 是否记录搜索词（可关）。
func SearchTermsEnabled() bool {
	v := strings.TrimSpace(strings.ToLower(settings.Get(settings.Type("usageSearchTerms"))))
	return v != "0" && v != "false" && v != "off"
}

var _ = mu
