package clientsession

import (
	"strings"
	"sync"
	"time"
)

// Presence 跟踪远端用户心跳，超时回收运行时。
type Presence struct {
	mu       sync.Mutex
	lastPing map[string]time.Time // userID -> last
	onExpire func(userID string)
	stop     chan struct{}
}

func NewPresence(onExpire func(userID string)) *Presence {
	p := &Presence{
		lastPing: map[string]time.Time{},
		onExpire: onExpire,
		stop:     make(chan struct{}),
	}
	go p.loop()
	return p
}

func (p *Presence) Ping(userID string) {
	userID = strings.TrimSpace(userID)
	if userID == "" {
		return
	}
	p.mu.Lock()
	p.lastPing[userID] = time.Now()
	p.mu.Unlock()
}

func (p *Presence) Leave(userID string) {
	userID = strings.TrimSpace(userID)
	if userID == "" {
		return
	}
	p.mu.Lock()
	delete(p.lastPing, userID)
	p.mu.Unlock()
	if p.onExpire != nil {
		p.onExpire(userID)
	}
}

// Online 返回最近仍有心跳的用户 ID 与最后活跃时间。
func (p *Presence) Online(within time.Duration) []struct {
	UserID   string
	LastPing time.Time
} {
	if p == nil {
		return nil
	}
	if within <= 0 {
		within = 90 * time.Second
	}
	deadline := time.Now().Add(-within)
	p.mu.Lock()
	defer p.mu.Unlock()
	out := make([]struct {
		UserID   string
		LastPing time.Time
	}, 0, len(p.lastPing))
	for id, ts := range p.lastPing {
		if ts.Before(deadline) {
			continue
		}
		out = append(out, struct {
			UserID   string
			LastPing time.Time
		}{UserID: id, LastPing: ts})
	}
	return out
}

func (p *Presence) Stop() {
	select {
	case <-p.stop:
	default:
		close(p.stop)
	}
}

func (p *Presence) loop() {
	t := time.NewTicker(30 * time.Second)
	defer t.Stop()
	for {
		select {
		case <-p.stop:
			return
		case <-t.C:
			p.sweep()
		}
	}
}

func (p *Presence) sweep() {
	deadline := time.Now().Add(-90 * time.Second)
	var expired []string
	p.mu.Lock()
	for id, ts := range p.lastPing {
		if ts.Before(deadline) {
			expired = append(expired, id)
			delete(p.lastPing, id)
		}
	}
	p.mu.Unlock()
	for _, id := range expired {
		if p.onExpire != nil {
			p.onExpire(id)
		}
	}
}

// Remove 从 Hub 删除会话。
func (h *Hub) Remove(clientID string) {
	clientID = strings.TrimSpace(clientID)
	if clientID == "" {
		return
	}
	h.mu.Lock()
	delete(h.byID, clientID)
	h.mu.Unlock()
}

// RemoveByUser 删除该远端用户的全部 Scope 会话（u:<userId>）。
func (h *Hub) RemoveByUser(userID string) {
	userID = strings.TrimSpace(userID)
	if userID == "" {
		return
	}
	key := "u:" + userID
	h.mu.Lock()
	delete(h.byID, key)
	// 兼容旧键
	for id := range h.byID {
		if id == userID || strings.HasSuffix(id, ":"+userID) {
			delete(h.byID, id)
		}
	}
	h.mu.Unlock()
}

// HasScopeForUser 是否还有该用户的会话（Leave 卸 Scope 后据此决定是否 KillUserRuntime）。
func (h *Hub) HasScopeForUser(userID string) bool {
	if h == nil {
		return false
	}
	userID = strings.TrimSpace(userID)
	if userID == "" {
		return false
	}
	key := "u:" + userID
	h.mu.Lock()
	defer h.mu.Unlock()
	if _, ok := h.byID[key]; ok {
		return true
	}
	for id := range h.byID {
		if id == userID || strings.HasSuffix(id, ":"+userID) {
			return true
		}
	}
	return false
}

// RemoveAll 清空全部会话。
func (h *Hub) RemoveAll() {
	h.mu.Lock()
	h.byID = map[string]*Session{}
	h.mu.Unlock()
}
