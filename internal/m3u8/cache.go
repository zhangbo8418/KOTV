package m3u8

import (
	"crypto/rand"
	"encoding/hex"
	"sync"
)

type Cache struct {
	mu   sync.RWMutex
	data map[string]string
}

var DefaultCache = NewCache()

func NewCache() *Cache {
	return &Cache{data: make(map[string]string)}
}

func (c *Cache) Put(content string) string {
	id := randomID()
	c.mu.Lock()
	// 仅保留当前播放列表；换片/换源后旧条目无复用价值。
	c.data = map[string]string{id: content}
	c.mu.Unlock()
	return id
}

func (c *Cache) Get(id string) (string, bool) {
	c.mu.RLock()
	defer c.mu.RUnlock()
	v, ok := c.data[id]
	return v, ok
}

func randomID() string {
	b := make([]byte, 8)
	_, _ = rand.Read(b)
	return hex.EncodeToString(b)
}
