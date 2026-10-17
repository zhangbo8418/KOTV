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
