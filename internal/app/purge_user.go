package app

import (
	"log"
	"os"
	"path/filepath"
	"strings"

	"github.com/bobo/KOTV/internal/parse"
	"github.com/bobo/KOTV/internal/paths"
	"github.com/bobo/KOTV/internal/spider"
)

// PurgeUserData 删除远端用户的全部用户态（不可对 owner='' 调用）。
func (a *App) PurgeUserData(userID string) {
	userID = strings.TrimSpace(userID)
	if a == nil || userID == "" {
		return
	}
	if a.DB != nil {
		if err := a.DB.ClearHistory(userID); err != nil {
			log.Printf("purge user %s history: %v", userID, err)
		}
		if err := a.DB.ClearKeep(userID); err != nil {
			log.Printf("purge user %s keep: %v", userID, err)
		}
		if err := a.DB.DeleteSettingsOwner(userID); err != nil {
			log.Printf("purge user %s settings: %v", userID, err)
		}
		_ = a.DB.DeleteAuthTokensForUser(userID)
	}
	a.dropReposForUser(userID)
	if a.sessions != nil {
		a.sessions.RemoveByUser(userID)
	}
	spider.KillUserRuntime(userID)
	parse.CancelUserSniffs(userID)
	// 清理迁移前残留目录
	_ = os.RemoveAll(filepath.Join(paths.Data(), "users", userID))
}
