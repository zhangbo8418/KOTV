package app

import (
	"fmt"
	"strings"

	"github.com/bobo/KOTV/internal/auth"
	"github.com/bobo/KOTV/internal/config"
	"github.com/bobo/KOTV/internal/database"
	"github.com/bobo/KOTV/internal/grouppolicy"
	"github.com/bobo/KOTV/internal/hostclient"
	"github.com/bobo/KOTV/internal/server"
)

// ErrNeedAdmin 与 HTTP 层共用，便于 errors.Is。
var ErrNeedAdmin = server.ErrNeedAdmin

// currentRequestIsAdmin 当前请求用户是否为管理员（本机无 userId 视为本机管理）。
func currentRequestIsAdmin() bool {
	uid := hostclient.DataOwner()
	if uid == "" {
		return true
	}
	u := auth.GetUser(uid)
	return u != nil && u.Role == auth.RoleAdmin && u.Enabled
}

// errUnlessSharedSourceAllowed 远端非管理员只能选用已在共享表中的源，且须在所属分组勾选集内。
func (a *App) errUnlessSharedSourceAllowed(typ int64, raw string) error {
	if a == nil || !hostclient.DedicatedRuntime() || currentRequestIsAdmin() {
		return nil
	}
	url := config.NormalizeSource(strings.TrimSpace(raw))
	if url == "" {
		return nil
	}
	uid := hostclient.DataOwner()
	u := auth.GetUser(uid)
	pol := grouppolicy.Resolve(u)
	if typ == database.ConfigTypeSite && !pol.AllowVodURL(url) {
		// 也试 normalize 匹配
		ok := false
		for allowed := range pol.VodURLs {
			if config.NormalizeSource(allowed) == url {
				ok = true
				break
			}
		}
		if !ok {
			return fmt.Errorf("当前分组不可用该仓库")
		}
	}
	var known map[string]struct{}
	if typ == database.ConfigTypeLive {
		known = a.liveSourceURLs()
	} else {
		known = a.siteRepoURLs()
	}
	if _, ok := known[url]; ok {
		return nil
	}
	for u := range known {
		if config.NormalizeSource(strings.TrimSpace(u)) == url {
			return nil
		}
	}
	return fmt.Errorf("%w", ErrNeedAdmin)
}
