// Package clientsession 按 Flutter clientId 隔离点播配置与 SiteService。
package clientsession

import (
	"sync"

	"github.com/bobo/KOTV/internal/config"
	"github.com/bobo/KOTV/internal/service"
)

// Session 单客户端的点播会话状态。
type Session struct {
	ClientID string
	Cfg      *config.Manager
	Sites    *service.SiteService
	Source   string
	Ready    bool
	ErrMsg   string
}

// Hub 按 clientId 持有独立 Session。
type Hub struct {
	mu   sync.Mutex
	byID map[string]*Session
}

func NewHub() *Hub {
	return &Hub{byID: map[string]*Session{}}
}

// GetOrCreate 返回已有会话，或用 factory 新建并登记。
func (h *Hub) GetOrCreate(id string, factory func() *Session) *Session {
	h.mu.Lock()
	defer h.mu.Unlock()
	if s, ok := h.byID[id]; ok {
		return s
	}
	s := factory()
	h.byID[id] = s
	return s
}
