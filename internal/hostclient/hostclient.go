// Package hostclient 在一次 HTTP/爬虫调用的 goroutine 上绑定前端 clientId / userId，
// 供 JAR bridge 请求携带，并把 /postMsg 与每用户运行时路由回正确客户端。
//
// 脚本文件（JAR/Py/JS 下载缓存）全局共享；仅「远端租户」请求使用独立 JVM/Py/JS 引擎。
package hostclient

import (
	"runtime"
	"strconv"
	"strings"
	"sync"
)

type binding struct {
	ClientID  string
	UserID    string
	Dedicated bool // 远端租户：独立引擎；本机/未开鉴权：共享引擎
}

var byG sync.Map // goroutine id -> binding

func goid() uint64 {
	var buf [64]byte
	n := runtime.Stack(buf[:], false)
	s := string(buf[:n])
	s = strings.TrimPrefix(s, "goroutine ")
	i := strings.IndexByte(s, ' ')
	if i <= 0 {
		return 0
	}
	id, _ := strconv.ParseUint(s[:i], 10, 64)
	return id
}

// Enter 绑定当前 goroutine 的 clientId（共享引擎）。
func Enter(id string) func() {
	return EnterSession(id, "", false)
}

// EnterBoth 兼容旧调用：有 userId 时默认视为需独立引擎（由中间件改用 EnterSession）。
func EnterBoth(clientID, userID string) func() {
	userID = strings.TrimSpace(userID)
	return EnterSession(clientID, userID, userID != "")
}

// EnterSession 绑定 clientId/userId，并声明是否使用独立运行时引擎。
// dedicated=false：本机或未开远端鉴权 → 共享 JVM/Py/JS；脚本仍全局缓存。
func EnterSession(clientID, userID string, dedicated bool) func() {
	clientID = strings.TrimSpace(clientID)
	userID = strings.TrimSpace(userID)
	if !dedicated {
		// 共享引擎路径不把 userId 用于运行时分桶（Kill 仍可用 CurrentUserID）
	}
	if clientID == "" && userID == "" && !dedicated {
		return func() {}
	}
	gid := goid()
	prev, _ := byG.Load(gid)
	byG.Store(gid, binding{ClientID: clientID, UserID: userID, Dedicated: dedicated && userID != ""})
	return func() {
		if prev == nil {
			byG.Delete(gid)
			return
		}
		byG.Store(gid, prev)
	}
}

// EnterUser 仅更新 userId，保留已有 clientId / dedicated。
func EnterUser(userID string) func() {
	userID = strings.TrimSpace(userID)
	gid := goid()
	prev, _ := byG.Load(gid)
	cid := ""
	dedicated := false
	if b, ok := prev.(binding); ok {
		cid = b.ClientID
		dedicated = b.Dedicated
	} else if s, ok := prev.(string); ok {
		cid = s
	}
	if userID == "" && cid == "" {
		return func() {}
	}
	byG.Store(gid, binding{ClientID: cid, UserID: userID, Dedicated: dedicated && userID != ""})
	return func() {
		if prev == nil {
			byG.Delete(gid)
			return
		}
		byG.Store(gid, prev)
	}
}

// Current 返回当前 goroutine 绑定的 clientId（无则空串）。
func Current() string {
	v, ok := byG.Load(goid())
	if !ok {
		return ""
	}
	if b, ok := v.(binding); ok {
		return b.ClientID
	}
	s, _ := v.(string)
	return s
}

// CurrentUserID 返回当前 goroutine 绑定的 userId（鉴权身份；无则空串）。
func CurrentUserID() string {
	v, ok := byG.Load(goid())
	if !ok {
		return ""
	}
	if b, ok := v.(binding); ok {
		return b.UserID
	}
	return ""
}

// RuntimeUserID 用于 JVM/Py/JS 引擎分桶：仅远端租户返回 userId，本机共享返回空。
func RuntimeUserID() string {
	v, ok := byG.Load(goid())
	if !ok {
		return ""
	}
	b, ok := v.(binding)
	if !ok || !b.Dedicated {
		return ""
	}
	return b.UserID
}

// DedicatedRuntime 当前请求是否走独立引擎。
func DedicatedRuntime() bool {
	return RuntimeUserID() != ""
}
