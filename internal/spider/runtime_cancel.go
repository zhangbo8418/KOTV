package spider

import (
	"strings"
	"sync"

	"github.com/bobo/KOTV/internal/hostclient"
	"github.com/bobo/KOTV/internal/paths"
	"github.com/bobo/KOTV/internal/util"
)

// 爬虫运行时取消 / 重启门面（JVM · Python · QuickJS · Node · Chromium）。
// 包外请只走本文件导出符号；底层 interrupt* 与嗅探钩子不导出。

// SoftCancelForClient 取消指定 Scope 下全部引擎进行中的调用。
// JAR：Go ctx + OkHttp cancel，不杀唯一 JVM、不清租户 Spider。
// Py/JS：打断匹配 Scope 的脚本槽；Node：只取消 in-flight，不停源包（配置网页仍挂原端口）。
// 卡死需 hard / KillUserRuntime / clearTenant。clientID 为空时 no-op。
func SoftCancelForClient(clientID string) {
	if clientID == "" {
		return
	}
	softCancelEngines(clientID)
}

// SoftCancelAll 打断全部 Scope 的进行中调用（清缓存等全局操作）。
// JAR：只 cancel in-flight，不杀唯一 JVM。Node：取消 in-flight 后 StopAll 源包进程。
// 不毁 Chromium 进程。与 SoftCancelForClient("") 的 no-op 不同。
func SoftCancelAll() {
	softCancelEngines("")
}

func softCancelEngines(clientID string) {
	interruptJavaBridgeForClient(clientID)
	cancelScopeHTTP(clientID)
	interruptScriptSpidersForClient(clientID) // Python + QuickJS
	interruptNodeForClient(clientID)
	if clientID == "" {
		stopAllNodePackages()
		runExtraSoftAll()
	} else {
		runExtraSoftScope(clientID)
	}
}

// stopAllNodePackages 停共享桶与全部用户桶内的 Node 进程（不清根别名等索引）。
func stopAllNodePackages() {
	for _, h := range snapshotNodeHosts() {
		h.StopAll()
	}
}

// HardRestartSharedRuntimes 本机共享运行时硬恢复：桌面停并重建唯一 JVM；安卓 /jar/interrupt→clearAll（不重启进程）。
// 另清本机共享 Py/JS/Node/Chromium。影响全体 JAR 租户；不动远端用户的 Py/Node/Chromium 桶，不删脚本磁盘缓存。
func HardRestartSharedRuntimes() {
	restartSharedRuntime()
	runExtraHardShared()
}

// forgetUserRuntimeState 收拢：用户离开时清 Go 侧按用户分桶的可变态。
func forgetUserRuntimeState(userID string) {
	userID = strings.TrimSpace(userID)
	if userID == "" {
		return
	}
	clearJarGoStateForRuntime(userID)
	clearJSRedirectsForUser(userID)
	clearNetConfigForUser(userID)
	clearPlayInfoForUser(userID)
	util.ClearHTTPAuthForUser(userID)
}

// KillUserRuntime 清指定用户在单 JVM 内的 bridge 租户态 + 删 UserJVMDir，并杀掉其 Py/JS/Node/Chromium。
// 不动唯一 JVM 进程与其它用户。
func KillUserRuntime(userID string) {
	userID = strings.TrimSpace(userID)
	if userID == "" {
		return
	}
	SoftCancelForClient("u:" + userID)
	forgetUserRuntimeState(userID)
	destroyUserScripts(userID)
	clearJarForUser(userID)
	clearBridgeTenant(userID)
	_, _ = paths.WipeDirRemove(paths.UserJVMDir(userID))
	destroyUserNodeHost(userID)
	runExtraKillUser(userID)
}

// RestartCallerRuntime 卡死恢复。切仓不走这里。
// 远端：仅 KillUserRuntime（不跟 HardRestart；桥挂由后续 ensureStarted/callCtx 按需重建）。
// 本机：SoftCancel → 清 shared 租户态；仅 bridge 不健康时才 HardRestart。
func RestartCallerRuntime() {
	if uid := hostclient.RuntimeUserID(); uid != "" {
		KillUserRuntime(uid)
		return
	}
	sid := hostclient.ScopeID()
	if sid != "" {
		SoftCancelForClient(sid)
	} else {
		SoftCancelAll()
	}
	clearSharedCallerState()
	if !javaBridgeHealthy() {
		HardRestartSharedRuntimes()
	}
}

// clearSharedCallerState 本机 shared：清 bridge 租户态 + Go net 桶 + 共享 Py/JS/Node（不动远端、不杀 JVM）。
func clearSharedCallerState() {
	clearJarGoStateForRuntime("")
	clearBridgeTenant("shared")
	clearNetConfigForShared()
	_, _ = paths.WipeDirRemove(paths.UserJVMDir(""))
	clearSharedJsPy()
	clearSharedJarSpiders()
	clearSharedNodeHost()
}

// ShutdownSniffBrowsers 关掉全部嗅探 Chromium（清缓存擦盘前；不碰 JVM/脚本）。
func ShutdownSniffBrowsers() {
	runExtraShutdown()
}

// ShutdownAllRuntimes 进程退出：先软取消，再硬清共享 + 销毁全部脚本/Node（含用户桶）+ 关 JVM + 全部 Chromium。
func ShutdownAllRuntimes() {
	SoftCancelAll()
	HardRestartSharedRuntimes()
	ResetScriptSpiders()
	ShutdownJavaBridge()
	ShutdownSniffBrowsers()
}

// --- 跨包附加钩子（Chromium 等，避免 spider↔parse 循环依赖）---

var (
	runtimeExtraMu sync.Mutex
	runtimeExtra   RuntimeExtraHooks
)

// RuntimeExtraHooks SoftCancel / Kill / HardRestart / Shutdown 的附加钩子。
type RuntimeExtraHooks struct {
	SoftCancelScope   func(scopeID string)
	SoftCancelAll     func()
	KillUser          func(userID string)
	HardRestartShared func()
	Shutdown          func()
}

// SetRuntimeExtraHooks 由 app 启动时注册（通常接 parse 嗅探）。
func SetRuntimeExtraHooks(h RuntimeExtraHooks) {
	runtimeExtraMu.Lock()
	defer runtimeExtraMu.Unlock()
	runtimeExtra = h
}

func withRuntimeExtra(fn func(RuntimeExtraHooks)) {
	runtimeExtraMu.Lock()
	h := runtimeExtra
	runtimeExtraMu.Unlock()
	fn(h)
}

func runExtraSoftScope(scopeID string) {
	withRuntimeExtra(func(h RuntimeExtraHooks) {
		if h.SoftCancelScope != nil {
			h.SoftCancelScope(scopeID)
		}
	})
}

func runExtraSoftAll() {
	withRuntimeExtra(func(h RuntimeExtraHooks) {
		if h.SoftCancelAll != nil {
			h.SoftCancelAll()
		}
	})
}

func runExtraKillUser(userID string) {
	withRuntimeExtra(func(h RuntimeExtraHooks) {
		if h.KillUser != nil {
			h.KillUser(userID)
		}
	})
}

func runExtraHardShared() {
	withRuntimeExtra(func(h RuntimeExtraHooks) {
		if h.HardRestartShared != nil {
			h.HardRestartShared()
		}
	})
}

func runExtraShutdown() {
	withRuntimeExtra(func(h RuntimeExtraHooks) {
		if h.Shutdown != nil {
			h.Shutdown()
		}
	})
}
