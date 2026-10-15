package app

import (
	"log"
	"strings"

	"github.com/bobo/KOTV/internal/clientsession"
	"github.com/bobo/KOTV/internal/hostclient"
	"github.com/bobo/KOTV/internal/settings"
)

// mirrorLocalSelectedVod 本机 Flutter（c:）换源成功后同步 settings.VOD，供冷启动 InitFromSettings。
// 远端租户（DedicatedRuntime / u:）仍只写 client_sessions，避免盖掉宿主当前源。
func mirrorLocalSelectedVod(sess *clientsession.Session, source string) {
	if sess == nil || hostclient.DedicatedRuntime() {
		return
	}
	if !strings.HasPrefix(strings.TrimSpace(sess.ClientID), "c:") {
		return
	}
	u := strings.TrimSpace(source)
	if u == "" {
		return
	}
	if settings.Get(settings.VOD) == u {
		return
	}
	settings.Set(settings.VOD, u)
	if err := settings.Save(); err != nil {
		log.Printf("保存当前点播源失败: %v", err)
	}
}
