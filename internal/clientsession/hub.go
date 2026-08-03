// Package clientsession 按 ScopeID（优先 userId）隔离点播/直播会话与媒体态。
package clientsession

import (
	"sync"

	"github.com/bobo/KOTV/internal/config"
	"github.com/bobo/KOTV/internal/live"
	"github.com/bobo/KOTV/internal/service"
)

// Session 单客户端的会话状态（点播配置 + 直播 + 媒体元数据）。
type Session struct {
	ClientID string
	Cfg      *config.Manager
	Sites    *service.SiteService
	Live     *live.Service
	Source   string
	Ready    bool
	ErrMsg   string
	// Bootstrapped 是否已尝试从磁盘恢复上次源（只做一次）。
	Bootstrapped bool

	mediaMu    sync.RWMutex
	mediaState string
	mediaTitle string
	mediaURL   string
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

func (s *Session) SetMediaPlaying(title, url string) {
	s.mediaMu.Lock()
	s.mediaState = "playing"
	s.mediaTitle = title
	s.mediaURL = url
	s.mediaMu.Unlock()
}

func (s *Session) SetMediaIdle() {
	s.mediaMu.Lock()
	s.mediaState = "idle"
	s.mediaTitle = ""
	s.mediaURL = ""
	s.mediaMu.Unlock()
}

func (s *Session) MediaURL() string {
	s.mediaMu.RLock()
	defer s.mediaMu.RUnlock()
	return s.mediaURL
}

func (s *Session) MediaTitle() string {
	s.mediaMu.RLock()
	defer s.mediaMu.RUnlock()
	return s.mediaTitle
}

func (s *Session) MediaSnapshot() map[string]string {
	s.mediaMu.RLock()
	defer s.mediaMu.RUnlock()
	st := s.mediaState
	if st == "" {
		st = "idle"
	}
	title := s.mediaTitle
	if title == "" {
		title = "未播放"
	}
	return map[string]string{
		"state": st,
		"title": title,
		"url":   s.mediaURL,
	}
}

func (s *Session) SetMediaSnapshot(m map[string]string) {
	s.mediaMu.Lock()
	defer s.mediaMu.Unlock()
	if m == nil {
		s.mediaState = "idle"
		s.mediaTitle = ""
		s.mediaURL = ""
		return
	}
	if v, ok := m["state"]; ok {
		s.mediaState = v
	}
	if v, ok := m["title"]; ok {
		s.mediaTitle = v
	}
	if v, ok := m["url"]; ok {
		s.mediaURL = v
	}
}
