package spider

import (
	"testing"

	"github.com/bobo/KOTV/internal/hostclient"
)

func TestJarPathIsolatedByUser(t *testing.T) {
	t.Cleanup(func() {
		jarPathByUser.Delete("")
		jarPathByUser.Delete("user-jar")
	})
	setCurrentJarPath("/local.jar")
	if got := currentJarPath(); got != "/local.jar" {
		t.Fatalf("local path %q", got)
	}
	leave := hostclient.EnterSession("c-jar", "user-jar", true)
	setCurrentJarPath("/user.jar")
	if got := currentJarPath(); got != "/user.jar" {
		leave()
		t.Fatalf("user path %q", got)
	}
	setCurrentJarPath("")
	if got := currentJarPath(); got != "" {
		leave()
		t.Fatalf("cleared user path %q", got)
	}
	leave()
	if got := currentJarPath(); got != "/local.jar" {
		t.Fatalf("local path changed %q", got)
	}
}

func TestJarRecentSkipWhileBridgeAlive(t *testing.T) {
	prev := bridgeAliveForRecent
	bridgeAliveForRecent = func() bool { return true }
	t.Cleanup(func() {
		bridgeAliveForRecent = prev
		forgetJarRecent("")
		forgetJarRecent("user-recent")
	})
	forgetJarRecent("")
	if jarRecentCanSkip("/a.jar") {
		t.Fatal("未记录 recent")
	}
	rememberJarRecent("/a.jar")
	if !jarRecentCanSkip("/a.jar") {
		t.Fatal("同一路径应跳过")
	}
	if jarRecentCanSkip("/b.jar") {
		t.Fatal("换路径不应跳过")
	}
	bridgeAliveForRecent = func() bool { return false }
	if jarRecentCanSkip("/a.jar") {
		t.Fatal("JVM 不在时不应跳过")
	}
	bridgeAliveForRecent = func() bool { return true }
	leave := hostclient.EnterSession("c-recent", "user-recent", true)
	defer leave()
	if jarRecentCanSkip("/a.jar") {
		t.Fatal("其他用户不应沿用本机 recent")
	}
	rememberJarRecent("/u.jar")
	if !jarRecentCanSkip("/u.jar") {
		t.Fatal("该用户自己的 recent 应跳过")
	}
}
