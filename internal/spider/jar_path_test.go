package spider

import (
	"errors"
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

func TestParseJarFailureRetriesNextTime(t *testing.T) {
	const path = "/retry.jar"
	calls := 0
	prev := callParseJar
	callParseJar = func([]byte) error {
		calls++
		if calls == 1 {
			return errors.New("down")
		}
		return nil
	}
	t.Cleanup(func() {
		callParseJar = prev
		parseJarNotified.Delete(jarRunKey(path))
		parseJarFlights.Delete(jarRunKey(path))
	})
	if err := notifyParseJar(path, false); err == nil {
		t.Fatal("第一次应失败")
	}
	if _, ok := parseJarNotified.Load(jarRunKey(path)); ok {
		t.Fatal("失败不应记成已加载")
	}
	if err := notifyParseJar(path, false); err != nil {
		t.Fatal(err)
	}
	if _, ok := parseJarNotified.Load(jarRunKey(path)); !ok {
		t.Fatal("成功后应记上")
	}
	if err := notifyParseJar(path, false); err != nil {
		t.Fatal(err)
	}
	if calls != 2 {
		t.Fatalf("成功后不应再请求，calls=%d", calls)
	}
}

func TestParseJarNotifiedSeparateByUser(t *testing.T) {
	const path = "/shared.jar"
	calls := 0
	prev := callParseJar
	callParseJar = func([]byte) error {
		calls++
		return nil
	}
	t.Cleanup(func() {
		callParseJar = prev
		parseJarNotified.Delete("\x01" + path)
	})
	if err := notifyParseJar(path, false); err != nil {
		t.Fatal(err)
	}
	leave := hostclient.EnterSession("c-parse", "other-parse", true)
	defer leave()
	other := jarRunKey(path)
	t.Cleanup(func() { parseJarNotified.Delete(other) })
	if err := notifyParseJar(path, false); err != nil {
		t.Fatal(err)
	}
	if calls != 2 {
		t.Fatalf("另一台 JVM 不应跳过，calls=%d", calls)
	}
}
