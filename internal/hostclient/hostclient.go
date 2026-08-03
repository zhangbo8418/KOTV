// Package hostclient 在一次 HTTP/爬虫调用的 goroutine 上绑定前端 clientId / userId，
// 供 JAR bridge 请求携带，并把 /postMsg 与每用户运行时路由回正确客户端。
package hostclient

import (
	"runtime"
	"strconv"
	"strings"
	"sync"
)

type binding struct {
	ClientID string
	UserID   string
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

// Enter 绑定当前 goroutine 的 clientId；返回的函数应 defer 调用以解除绑定。
func Enter(id string) func() {
	return EnterBoth(id, CurrentUserID())
}

// EnterBoth 同时绑定 clientId 与 userId。
func EnterBoth(clientID, userID string) func() {
	clientID = strings.TrimSpace(clientID)
	userID = strings.TrimSpace(userID)
	if clientID == "" && userID == "" {
		return func() {}
	}
	gid := goid()
	prev, _ := byG.Load(gid)
	byG.Store(gid, binding{ClientID: clientID, UserID: userID})
	return func() {
		if prev == nil {
			byG.Delete(gid)
			return
		}
		byG.Store(gid, prev)
	}
}

// EnterUser 仅更新 userId，保留已有 clientId。
func EnterUser(userID string) func() {
	userID = strings.TrimSpace(userID)
	gid := goid()
	prev, _ := byG.Load(gid)
	cid := ""
	if b, ok := prev.(binding); ok {
		cid = b.ClientID
	} else if s, ok := prev.(string); ok {
		cid = s
	}
	if userID == "" && cid == "" {
		return func() {}
	}
	byG.Store(gid, binding{ClientID: cid, UserID: userID})
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

// CurrentUserID 返回当前 goroutine 绑定的 userId（无则空串）。
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
