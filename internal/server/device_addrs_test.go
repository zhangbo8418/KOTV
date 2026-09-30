package server

import (
	"os"
	"testing"
)

func TestCollectDeviceAddrs_UsesInjectedLanIP(t *testing.T) {
	prev := os.Getenv("KOTV_LAN_IP")
	t.Cleanup(func() {
		if prev == "" {
			_ = os.Unsetenv("KOTV_LAN_IP")
		} else {
			_ = os.Setenv("KOTV_LAN_IP", prev)
		}
	})
	if err := os.Setenv("KOTV_LAN_IP", "192.168.31.168"); err != nil {
		t.Fatal(err)
	}
	info := collectDeviceAddrs()
	if info.Primary != "192.168.31.168" {
		t.Fatalf("Primary=%q want 192.168.31.168 (ipv4=%v)", info.Primary, info.IPv4)
	}
	found := false
	for _, s := range info.IPv4 {
		if s == "192.168.31.168" {
			found = true
			break
		}
	}
	if !found {
		t.Fatalf("ipv4 missing injected addr: %v", info.IPv4)
	}
}
