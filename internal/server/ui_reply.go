package server

import (
	"io"
	"net/http"
	"strings"
	"sync"
)

// uiReplyStore 保存通用 UI 会话的单次回传；id 由调用方生成，宿主不解释其业务含义。
type uiReplyStore struct {
	mu sync.Mutex
	m  map[string]string
}

func newUIReplyStore() *uiReplyStore {
	return &uiReplyStore{m: map[string]string{}}
}

func (s *uiReplyStore) put(id, value string) {
	id = strings.TrimSpace(id)
	if id == "" || value == "" {
		return
	}
	s.mu.Lock()
	s.m[id] = value
	s.mu.Unlock()
}

func (s *uiReplyStore) take(id string) string {
	id = strings.TrimSpace(id)
	s.mu.Lock()
	defer s.mu.Unlock()
	v := s.m[id]
	delete(s.m, id)
	return v
}

func (s *Server) handleUIReply(w http.ResponseWriter, r *http.Request) {
	if s.uiReply == nil {
		s.uiReply = newUIReplyStore()
	}
	switch r.Method {
	case http.MethodGet:
		id := r.URL.Query().Get("id")
		v := s.uiReply.take(id)
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		_, _ = w.Write([]byte(v))
	case http.MethodPost:
		id := strings.TrimSpace(r.URL.Query().Get("id"))
		if id == "" {
			http.Error(w, "missing id", http.StatusBadRequest)
			return
		}
		body, _ := io.ReadAll(io.LimitReader(r.Body, 256<<10))
		event := strings.TrimSpace(string(body))
		if event == "" {
			http.Error(w, "missing event", http.StatusBadRequest)
			return
		}
		s.uiReply.put(id, event)
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("OK"))
	default:
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
	}
}
