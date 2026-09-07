// Package localproxy 提供本地爬虫代理端口，避免 spider 与 server 循环依赖。
package localproxy

import (
	"fmt"
	"net/url"
	"strings"
	"sync/atomic"

	"github.com/bobo/KOTV/internal/hostclient"
	"github.com/bobo/KOTV/internal/util"
)

const DefaultPort = 9978

var port atomic.Int32

func init() {
	port.Store(DefaultPort)
}

func SetPort(p int) {
	if p > 0 {
		port.Store(int32(p))
	}
}

func Port() int {
	p := int(port.Load())
	if p <= 0 {
		return DefaultPort
	}
	return p
}

func BaseURL(local bool) string {
	if !local {
		// 远端请求：优先当前对外根（域名/反代），避免把局域网 IP 交给客户端。
		if b := strings.TrimRight(strings.TrimSpace(hostclient.PublicBase()), "/"); b != "" {
			return b + "/proxy"
		}
		if ip := util.LanIP(); ip != "" {
			return fmt.Sprintf("http://%s:%d/proxy", ip, Port())
		}
	}
	return fmt.Sprintf("http://127.0.0.1:%d/proxy", Port())
}

func URL(do, siteKey string, local bool) string {
	u := BaseURL(local) + "?do=" + url.QueryEscape(do)
	if siteKey != "" {
		u += "&siteKey=" + url.QueryEscape(siteKey)
	}
	return u
}
