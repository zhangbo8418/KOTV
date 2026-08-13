// Package localproxy 提供本地爬虫代理端口，避免 spider 与 server 循环依赖。
package localproxy

import (
	"fmt"
	"net/url"
	"sync/atomic"

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
	host := "127.0.0.1"
	if !local {
		// Proxy.getUrl(false)：局域网 IP，供外设回调
		if ip := util.LanIP(); ip != "" {
			host = ip
		}
	}
	return fmt.Sprintf("http://%s:%d/proxy", host, Port())
}

func URL(do, siteKey string, local bool) string {
	u := BaseURL(local) + "?do=" + url.QueryEscape(do)
	if siteKey != "" {
		u += "&siteKey=" + url.QueryEscape(siteKey)
	}
	return u
}
