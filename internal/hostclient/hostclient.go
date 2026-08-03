// Package hostclient 在一次 HTTP/爬虫调用的 goroutine 上绑定前端 clientId，
// 供 JAR bridge 请求携带，从而把 /postMsg 路由回正确的 Flutter 客户端。
package hostclient

import (
	"runtime"
	"strconv"
	"strings"
	"sync"
)

var byG sync.Map // goroutine id -> clientId

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
	id = strings.TrimSpace(id)
	if id == "" {
		return func() {}
	}
	gid := goid()
	byG.Store(gid, id)
	return func() { byG.Delete(gid) }
}

// Current 返回当前 goroutine 绑定的 clientId（无则空串）。
func Current() string {
	v, ok := byG.Load(goid())
	if !ok {
		return ""
	}
	s, _ := v.(string)
	return s
}
