package server

import (
	"fmt"
	"net/http"
	"strings"
	"time"

	"github.com/bobo/KOTV/internal/auth"
	"github.com/bobo/KOTV/internal/database"
	"github.com/bobo/KOTV/internal/grouppolicy"
	"github.com/bobo/KOTV/internal/usage"
)

func usageCtx(r *http.Request) usage.Context {
	return usage.FromRequest(r, authUserFrom(r.Context()))
}

func recordUsage(r *http.Request, kind, refType, refID, refName string, ok bool, errCode string, started time.Time) {
	lat := int64(0)
	if !started.IsZero() {
		lat = time.Since(started).Milliseconds()
	}
	usage.Record(usageCtx(r), kind, refType, refID, refName, ok, errCode, lat)
}

// configRemarkName 有备注名返回备注，否则空（调用方回退显示地址）。
func (s *Server) configRemarkName(url string, typ int64) string {
	url = strings.TrimSpace(url)
	if url == "" || s == nil {
		return ""
	}
	db := s.adminDB()
	if db == nil {
		return ""
	}
	c, err := db.FindConfig(url, typ)
	if err != nil || c == nil {
		return ""
	}
	return strings.TrimSpace(c.Name)
}

// enrichConfigRefNames 用配置表备注名补全统计行（有名用名，无名保留地址）。
func enrichConfigRefNames(db *database.DB, rows []map[string]any, typ int64) {
	if db == nil || len(rows) == 0 {
		return
	}
	cfgs, err := db.ListConfigs(typ)
	if err != nil || len(cfgs) == 0 {
		return
	}
	byURL := make(map[string]string, len(cfgs))
	for _, c := range cfgs {
		u := strings.TrimSpace(c.URL)
		n := strings.TrimSpace(c.Name)
		if u == "" || n == "" {
			continue
		}
		byURL[u] = n
	}
	for _, row := range rows {
		id := strings.TrimSpace(fmt.Sprint(row["refId"]))
		cur := strings.TrimSpace(fmt.Sprint(row["refName"]))
		if id == "" {
			continue
		}
		if cur != "" && cur != id && cur != "<nil>" {
			continue
		}
		if n, ok := byURL[id]; ok {
			row["refName"] = n
		}
	}
}

// enforceGroupPolicy 在 needUser API 上拦维护/IP/时段/账号状态；admin 与本机豁免。
// 返回 true 表示已写响应并应中止。
func enforceGroupPolicy(w http.ResponseWriter, r *http.Request) bool {
	if isLocalNative(r) {
		return false
	}
	user := authUserFrom(r.Context())
	if user != nil && user.Role == auth.RoleAdmin {
		return false
	}
	pol := grouppolicy.Resolve(user)
	ip := clientIP(r)
	reason, code := pol.AccessDeny(user, ip)
	if reason == "" {
		return false
	}
	usage.Record(usageCtx(r), "policy_deny", "policy", code, reason, false, code, 0)
	writeAPIError(w, http.StatusForbidden, reason)
	return true
}

func clientIP(r *http.Request) string {
	if r == nil {
		return ""
	}
	if xff := strings.TrimSpace(r.Header.Get("X-Forwarded-For")); xff != "" {
		if i := strings.IndexByte(xff, ','); i > 0 {
			return strings.TrimSpace(xff[:i])
		}
		return xff
	}
	if xri := strings.TrimSpace(r.Header.Get("X-Real-IP")); xri != "" {
		return xri
	}
	host := r.RemoteAddr
	if i := strings.LastIndex(host, ":"); i > 0 && !strings.Contains(host, "]") {
		host = host[:i]
	}
	return host
}
