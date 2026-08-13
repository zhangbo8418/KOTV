package util

import (
	"net"
	"strings"
)

// LanIP Util.getIp：优先非回环 IPv4（wlan/eth 名优先）。
func LanIP() string {
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
