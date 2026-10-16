package dlna

import (
	"os"
	"strings"
	"testing"
)

func TestRewriteLocalURL_ReplacesLoopback(t *testing.T) {
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

	in := "http://127.0.0.1:9978/proxy/play?id=a"
	got := RewriteLocalURL(in)
	want := "http://192.168.31.168:9978/proxy/play?id=a"
	if got != want {
		t.Fatalf("RewriteLocalURL(%q)=%q want %q", in, got, want)
	}

	if !IsLoopbackMediaURL(in) {
		t.Fatal("expected loopback before rewrite")
	}
	if IsLoopbackMediaURL(got) {
		t.Fatalf("expected non-loopback after rewrite: %q", got)
	}
}

func TestRewriteLocalURL_LiteralReplace(t *testing.T) {
	prev := os.Getenv("KOTV_LAN_IP")
	t.Cleanup(func() {
		if prev == "" {
			_ = os.Unsetenv("KOTV_LAN_IP")
		} else {
			_ = os.Setenv("KOTV_LAN_IP", prev)
		}
	})
	_ = os.Setenv("KOTV_LAN_IP", "10.0.0.2")

	// 非法但含字面量时仍替换，避免电视收到 127。
	in := "not-a-url-127.0.0.1:9978/x"
	got := RewriteLocalURL(in)
	if strings.Contains(got, "127.0.0.1") {
		t.Fatalf("still contains loopback: %q", got)
	}
	if !strings.Contains(got, "10.0.0.2") {
		t.Fatalf("missing lan ip: %q", got)
	}
}

func TestRewriteLocalURL_NoLanLeavesRaw(t *testing.T) {
	prev := os.Getenv("KOTV_LAN_IP")
	t.Cleanup(func() {
		if prev == "" {
			_ = os.Unsetenv("KOTV_LAN_IP")
		} else {
			_ = os.Setenv("KOTV_LAN_IP", prev)
		}
	})
	_ = os.Unsetenv("KOTV_LAN_IP")
	// 不保证 Interfaces 为空；若有系统 IP 则改写成功也算通过。
	in := "http://127.0.0.1:9978/proxy/x"
	got := RewriteLocalURL(in)
	if LocalIP() == "" && got != in {
		t.Fatalf("empty LanIP should leave raw, got %q", got)
	}
	if LocalIP() != "" && IsLoopbackMediaURL(got) {
		t.Fatalf("LanIP set but still loopback: %q", got)
	}
}
