package spider

import (
	"errors"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os/exec"
	goruntime "runtime"
	"strconv"
	"testing"
	"time"

	"github.com/bobo/KOTV/internal/hostclient"
)

func TestSoftCancelForClient_EmptyNoop(t *testing.T) {
	SoftCancelForClient("") // 无 Scope 时不得打断全部会话
}

func TestSoftCancelAll_DoesNotPanic(t *testing.T) {
	SoftCancelAll()
}

func TestCancelSharedJarCalls_LeavesUserInflight(t *testing.T) {
	sharedCtx, endShared := beginJarCall("c:local")
	userCtx, endUser := beginJarCall("u:alice")
	t.Cleanup(func() {
		endShared()
		endUser()
	})
	cancelSharedJarCalls()
	select {
	case <-sharedCtx.Done():
	default:
		t.Fatal("shared jar call should be cancelled")
	}
	select {
	case <-userCtx.Done():
		t.Fatal("user jar call must survive shared cancel")
	default:
	}
}

func TestForgetUserRuntimeState_Consolidated(t *testing.T) {
	leave := hostclient.EnterSession("c-forget", "forget-u", true)
	path := "/forget.jar"
	key := jarRunKey(path)
	parseJarNotified.Store(key, struct{}{})
	jarPathByUser.Store("forget-u", path)
	configBaseByClient.Store("u:forget-u", "http://ex/")
	leave()
	jsRedirectsMu.Lock()
	jsRedirectsByUser["forget-u"] = nil
	jsRedirectsMu.Unlock()
	netConfigMu.Lock()
	if netConfigByClient == nil {
		netConfigByClient = map[string][]byte{}
	}
	netConfigByClient["u:forget-u"] = []byte(`{}`)
	netConfigMu.Unlock()
	t.Cleanup(func() {
		parseJarNotified.Delete(key)
		clearJSRedirectsForUser("forget-u")
		clearNetConfigForUser("forget-u")
	})

	forgetUserRuntimeState("forget-u")
	if _, ok := parseJarNotified.Load(key); ok {
		t.Fatal("jar go state should be cleared")
	}
	jsRedirectsMu.Lock()
	_, redirOK := jsRedirectsByUser["forget-u"]
	jsRedirectsMu.Unlock()
	if redirOK {
		t.Fatal("js redirects should be cleared")
	}
	netConfigMu.Lock()
	_, netOK := netConfigByClient["u:forget-u"]
	netConfigMu.Unlock()
	if netOK {
		t.Fatal("net config should be cleared")
	}
}

func TestBridgeForCurrent_SoleJVM(t *testing.T) {
	if bridgeForCurrent() != &javaBridge {
		t.Fatal("bridgeForCurrent must be sole javaBridge")
	}
}

func TestCallCtxStopBumpsEpoch(t *testing.T) {
	if goruntime.GOOS == "android" {
		t.Skip("desktop only")
	}
	javaBridge.mu.Lock()
	javaBridge.cmd = nil
	javaBridge.baseURL = ""
	before := javaBridge.epoch.Load()
	javaBridge.mu.Unlock()
	if !javaBridge.shouldRestartAfterTransportErr() {
		t.Fatal("dead bridge should allow restart")
	}
	javaBridge.epoch.Add(1)
	javaBridge.mu.Lock()
	javaBridge.stopLocked()
	after := javaBridge.epoch.Load()
	javaBridge.mu.Unlock()
	if after != before+1 {
		t.Fatalf("epoch want %d got %d", before+1, after)
	}
}

func TestShouldRestartAfterTransportErr_DeadAllowsRestart(t *testing.T) {
	if goruntime.GOOS == "android" {
		t.Skip("desktop only")
	}
	javaBridge.mu.Lock()
	javaBridge.cmd = nil
	javaBridge.baseURL = ""
	javaBridge.mu.Unlock()
	if !javaBridge.shouldRestartAfterTransportErr() {
		t.Fatal("dead bridge should allow restart")
	}
}

func TestBridgeHealthFailedTwice(t *testing.T) {
	ok := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusOK)
	}))
	defer ok.Close()
	if bridgeHealthFailedTwice(ok.URL) {
		t.Fatal("healthy endpoint must not count as failed twice")
	}
	if !bridgeHealthFailedTwice("http://127.0.0.1:1") {
		t.Fatal("down endpoint should fail twice")
	}
}

func TestShouldRestartAfterTransportErr_AliveHealthyNoRestart(t *testing.T) {
	if goruntime.GOOS == "android" {
		t.Skip("desktop only")
	}
	ok := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusOK)
	}))
	defer ok.Close()
	cmd := exec.Command("sleep", "30")
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		_ = cmd.Process.Kill()
		_ = cmd.Wait()
	})
	javaBridge.mu.Lock()
	prevCmd, prevURL := javaBridge.cmd, javaBridge.baseURL
	javaBridge.cmd = cmd
	javaBridge.baseURL = ok.URL
	javaBridge.mu.Unlock()
	t.Cleanup(func() {
		javaBridge.mu.Lock()
		javaBridge.cmd = prevCmd
		javaBridge.baseURL = prevURL
		javaBridge.mu.Unlock()
	})
	if javaBridge.shouldRestartAfterTransportErr() {
		t.Fatal("alive+healthy must not restart sole JVM")
	}
}

func TestClearNetConfigForShared_LeavesRemote(t *testing.T) {
	netConfigMu.Lock()
	oldDef, oldProxy := netConfigJSON, userProxyJSON
	oldBy, oldProxyBy := netConfigByClient, userProxyByClient
	netConfigJSON = []byte(`{"def":1}`)
	userProxyJSON = []byte(`{"proxy":"def"}`)
	netConfigByClient = map[string][]byte{
		"c:win":   []byte(`{"local":1}`),
		"u:alice": []byte(`{"alice":1}`),
	}
	userProxyByClient = map[string][]byte{
		"c:win":   []byte(`{"proxy":"local"}`),
		"u:alice": []byte(`{"proxy":"alice"}`),
	}
	netConfigMu.Unlock()
	t.Cleanup(func() {
		netConfigMu.Lock()
		netConfigJSON, userProxyJSON = oldDef, oldProxy
		netConfigByClient, userProxyByClient = oldBy, oldProxyBy
		netConfigMu.Unlock()
	})
	clearNetConfigForShared()
	netConfigMu.Lock()
	defer netConfigMu.Unlock()
	if netConfigJSON != nil || userProxyJSON != nil {
		t.Fatal("shared defaults should be cleared")
	}
	if _, ok := netConfigByClient["c:win"]; ok {
		t.Fatal("local c: net should be cleared")
	}
	if _, ok := netConfigByClient["u:alice"]; !ok {
		t.Fatal("remote u: net must remain")
	}
	if _, ok := userProxyByClient["u:alice"]; !ok {
		t.Fatal("remote u: proxy must remain")
	}
}

func TestRestartCallerRuntime_RemoteOnlyKillUser(t *testing.T) {
	if goruntime.GOOS == "android" {
		t.Skip("desktop only")
	}
	// 故意把 health 指到不可达地址：若远端仍误跟 HardRestart，会 stopLocked 清掉 cmd。
	cmd := exec.Command("sleep", "30")
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		_ = cmd.Process.Kill()
		_ = cmd.Wait()
	})
	javaBridge.mu.Lock()
	prevCmd, prevURL := javaBridge.cmd, javaBridge.baseURL
	javaBridge.cmd = cmd
	javaBridge.baseURL = "http://127.0.0.1:1"
	javaBridge.mu.Unlock()
	t.Cleanup(func() {
		javaBridge.mu.Lock()
		javaBridge.cmd = prevCmd
		javaBridge.baseURL = prevURL
		javaBridge.mu.Unlock()
	})
	leave := hostclient.Bind(hostclient.Request{UserID: "restart-remote", Dedicated: true})
	defer leave()
	RestartCallerRuntime()
	javaBridge.mu.Lock()
	same := javaBridge.cmd == cmd
	javaBridge.mu.Unlock()
	if !same {
		t.Fatal("remote RestartCallerRuntime must KillUser only; must not HardRestart sole JVM")
	}
}

func TestNodePostJSON_SoftCancelStopsPackage(t *testing.T) {
	started := make(chan struct{})
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		close(started)
		time.Sleep(3 * time.Second)
		_, _ = w.Write([]byte(`{}`))
	}))
	defer srv.Close()

	u, err := url.Parse(srv.URL)
	if err != nil {
		t.Fatal(err)
	}
	port, err := strconv.Atoi(u.Port())
	if err != nil || port <= 0 {
		t.Fatalf("bad port: %v", u.Port())
	}
	h := sharedNodeHost
	pkg := &nodePkg{id: "inflight-cancel-test", port: port, ownerUID: "", host: h}
	h.mu.Lock()
	h.pkgs[pkg.id] = pkg
	h.mu.Unlock()
	t.Cleanup(func() {
		h.mu.Lock()
		delete(h.pkgs, pkg.id)
		h.mu.Unlock()
	})

	leave := hostclient.Enter("test-client-node")
	defer leave()
	snap := hostclient.Snapshot()
	scope := hostclient.ScopeID()

	errCh := make(chan error, 1)
	go func() {
		defer hostclient.Bind(snap)()
		_, err := pkg.PostJSON("/play", map[string]any{"a": 1})
		errCh <- err
	}()

	select {
	case <-started:
	case <-time.After(2 * time.Second):
		t.Fatal("handler not started")
	}
	SoftCancelForClient(scope)
	select {
	case err := <-errCh:
		if !errors.Is(err, ErrNodeInterrupted) {
			t.Fatalf("got %v want ErrNodeInterrupted", err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("PostJSON did not return after soft cancel")
	}
	if pkg.Port() != 0 {
		t.Fatalf("port=%d want 0 after soft cancel StopAll", pkg.Port())
	}
}

func TestSoftCancelForClient_StopsIdleSharedNode(t *testing.T) {
	h := sharedNodeHost
	pkg := &nodePkg{id: "idle-soft-cancel-node", port: 65432, ownerUID: "", host: h}
	h.mu.Lock()
	h.pkgs[pkg.id] = pkg
	h.mu.Unlock()
	t.Cleanup(func() {
		h.mu.Lock()
		delete(h.pkgs, pkg.id)
		h.mu.Unlock()
	})
	leave := hostclient.Enter("idle-soft-cancel-client")
	defer leave()
	SoftCancelForClient(hostclient.ScopeID())
	if pkg.Port() != 0 {
		t.Fatalf("idle shared node port=%d want 0", pkg.Port())
	}
}

func TestSoftCancelForClient_StopsOnlyScopeUserNode(t *testing.T) {
	sharedPkg := &nodePkg{id: "soft-shared-keep", port: 61001, ownerUID: ""}
	sharedNodeHost.mu.Lock()
	sharedNodeHost.pkgs[sharedPkg.id] = sharedPkg
	sharedNodeHost.mu.Unlock()

	user := nodeHostForUser("soft-cancel-user")
	userPkg := &nodePkg{id: "soft-user-stop", port: 61002, ownerUID: "soft-cancel-user", host: user}
	user.mu.Lock()
	user.pkgs[userPkg.id] = userPkg
	user.mu.Unlock()
	t.Cleanup(func() {
		sharedNodeHost.mu.Lock()
		delete(sharedNodeHost.pkgs, sharedPkg.id)
		sharedNodeHost.mu.Unlock()
		destroyUserNodeHost("soft-cancel-user")
	})

	SoftCancelForClient("u:soft-cancel-user")
	if userPkg.Port() != 0 {
		t.Fatalf("user node port=%d want 0", userPkg.Port())
	}
	if sharedPkg.Port() != 61001 {
		t.Fatalf("shared node should survive other user soft cancel, port=%d", sharedPkg.Port())
	}
}

func TestRestartSharedRuntime_StopsSharedNodeOnly(t *testing.T) {
	shared := sharedNodeHost
	sharedPkg := &nodePkg{id: "restart-shared-node", port: 8888, ownerUID: ""}
	shared.mu.Lock()
	shared.pkgs[sharedPkg.id] = sharedPkg
	shared.mu.Unlock()

	user := nodeHostForUser("user-keep-node")
	userPkg := &nodePkg{id: "restart-user-node", port: 7777, ownerUID: "user-keep-node", host: user}
	user.mu.Lock()
	user.pkgs[userPkg.id] = userPkg
	user.mu.Unlock()

	t.Cleanup(func() {
		shared.mu.Lock()
		delete(shared.pkgs, sharedPkg.id)
		shared.mu.Unlock()
		destroyUserNodeHost("user-keep-node")
	})

	HardRestartSharedRuntimes()
	if sharedPkg.Port() != 0 {
		t.Fatalf("shared node port=%d after hard restart", sharedPkg.Port())
	}
	if userPkg.Port() != 7777 {
		t.Fatalf("user node should survive shared restart, port=%d", userPkg.Port())
	}
}

func TestNodeHostPerUserIsolation(t *testing.T) {
	u1 := nodeHostForUser("iso-u1")
	u2 := nodeHostForUser("iso-u2")
	if u1 == u2 || u1 == sharedNodeHost || u2 == sharedNodeHost {
		t.Fatal("dedicated users must get distinct hosts")
	}
	p1 := &nodePkg{id: "same-pkg", port: 1001, ownerUID: "iso-u1", host: u1}
	p2 := &nodePkg{id: "same-pkg", port: 1002, ownerUID: "iso-u2", host: u2}
	u1.mu.Lock()
	u1.pkgs[p1.id] = p1
	u1.mu.Unlock()
	u2.mu.Lock()
	u2.pkgs[p2.id] = p2
	u2.mu.Unlock()
	t.Cleanup(func() {
		destroyUserNodeHost("iso-u1")
		destroyUserNodeHost("iso-u2")
	})

	destroyUserNodeHost("iso-u1")
	if p1.Port() != 0 {
		t.Fatal("KillUser-equivalent should stop only u1 pkg")
	}
	if p2.Port() != 1002 {
		t.Fatal("u2 pkg must remain after destroying u1")
	}
	if nodeHostForUser("iso-u1") == u1 {
		t.Fatal("destroyed user host should be recreated on next access")
	}
}

func TestPySpiderInterrupt_DesktopBusyDoesNotDeadlock(t *testing.T) {
	if goruntime.GOOS == "android" {
		t.Skip("android interrupt 走 bridge")
	}
	s := &pySpider{}
	s.activeClient.Store("c1")
	s.mu.Lock()
	done := make(chan struct{})
	go func() {
		s.interrupt()
		close(done)
	}()
	select {
	case <-done:
	case <-time.After(time.Second):
		s.mu.Unlock()
		t.Fatal("interrupt deadlocked on mu")
	}
	s.mu.Unlock()

	s.activeClient.Store("")
	s.interrupt()
}

func TestInterruptScriptSpiders_PerSlotClient(t *testing.T) {
	jsPyMu.Lock()
	saved := jsPy
	jsPy = map[string]Spider{}
	jsPyMu.Unlock()
	t.Cleanup(func() {
		jsPyMu.Lock()
		jsPy = saved
		jsPyMu.Unlock()
	})

	a := &pySpider{}
	a.activeClient.Store("c-a")
	a.epoch.Store(1)
	b := &pySpider{}
	b.activeClient.Store("c-b")
	b.epoch.Store(1)
	pool := &pyPool{}
	pool.slots = []*pySpider{a, b}
	jsPyMu.Lock()
	jsPy["pool"] = pool
	jsPyMu.Unlock()

	interruptScriptSpidersForClient("c-a")
	if a.epoch.Load() == 1 {
		t.Fatal("slot a should be interrupted")
	}
	if b.epoch.Load() != 1 {
		t.Fatal("slot b must not be interrupted for other client")
	}
}
