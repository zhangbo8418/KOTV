package util

import (
	"net"
	"os"
	"strings"
)

// LanIP 优先环境变量 KOTV_LAN_IP（安卓由 Java 注入，规避 netlinkrib）；
// 再回退 net.Interfaces（桌面正常；安卓 11+ 常失败）。
func LanIP() string {
	if v := strings.TrimSpace(os.Getenv("KOTV_LAN_IP")); v != "" {
		if ip := net.ParseIP(v); ip != nil && ip.To4() != nil && !ip.IsLoopback() {
			return ip.To4().String()
		}
	}
	ifaces, err := net.Interfaces()
	if err != nil {
		return ""
	}
	pick := func(prefix string) string {
		for _, iface := range ifaces {
			name := strings.ToLower(iface.Name)
			if prefix != "" && !strings.HasPrefix(name, prefix) {
				continue
			}
			if iface.Flags&net.FlagUp == 0 || iface.Flags&net.FlagLoopback != 0 {
				continue
			}
			addrs, err := iface.Addrs()
			if err != nil {
				continue
			}
			for _, a := range addrs {
				ipNet, ok := a.(*net.IPNet)
				if !ok || ipNet.IP == nil {
					continue
				}
				ip := ipNet.IP.To4()
				if ip == nil || ip.IsLoopback() {
					continue
				}
				return ip.String()
			}
		}
		return ""
	}
	for _, p := range []string{"wlan", "en", "eth", "wl", ""} {
		if ip := pick(p); ip != "" {
			return ip
		}
	}
	return ""
}
