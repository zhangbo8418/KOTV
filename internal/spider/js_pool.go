package spider

import (
	"context"
	"sync"
)

// jsPool 同站 QuickJS Runtime 池：每个 slot 独立 Runtime，多用户可并行打同一站。
type jsPool struct {
	key, api, ext, jar string

	mu      sync.Mutex
	slots   []*jsSpider
	max     int
	waiters []chan struct{}
	busy    []bool
}

func newJsPool(key, api, ext, jar string) *jsPool {
	return &jsPool{key: key, api: api, ext: ext, jar: jar, max: scriptPoolSize()}
}

func newJsSpiderWorker(key, api, ext, jar string) *jsSpider {
	return &jsSpider{
		key:    key,
		api:    api,
		ext:    ext,
		jar:    jar,
		reqCh:  make(chan jsReq, 8),
		quitCh: make(chan struct{}),
		timers: map[int32]context.CancelFunc{},
	}
}

func (p *jsPool) acquire() (*jsSpider, int) {
	p.mu.Lock()
	for {
		for i, s := range p.slots {
			if !p.busy[i] {
				p.busy[i] = true
				p.mu.Unlock()
				return s, i
			}
		}
		if len(p.slots) < p.max {
			s := newJsSpiderWorker(p.key, p.api, p.ext, p.jar)
			p.slots = append(p.slots, s)
			p.busy = append(p.busy, true)
			idx := len(p.slots) - 1
			p.mu.Unlock()
			return s, idx
		}
		ch := make(chan struct{}, 1)
		p.waiters = append(p.waiters, ch)
		p.mu.Unlock()
		<-ch
		p.mu.Lock()
	}
}

func (p *jsPool) release(idx int) {
	p.mu.Lock()
	if idx >= 0 && idx < len(p.busy) {
		p.busy[idx] = false
	}
	if len(p.waiters) > 0 {
		ch := p.waiters[0]
		p.waiters = p.waiters[1:]
		p.mu.Unlock()
		ch <- struct{}{}
		return
	}
	p.mu.Unlock()
}

func (p *jsPool) matchesClient(clientID string) bool {
	if clientID == "" {
		return true
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	for _, s := range p.slots {
		if s.activeClientID() == clientID {
			return true
		}
	}
	return false
}

func (p *jsPool) interrupt() {
	p.mu.Lock()
	slots := append([]*jsSpider(nil), p.slots...)
	p.mu.Unlock()
	for _, s := range slots {
		s.interrupt()
	}
}

func (p *jsPool) withSlot(fn func(s *jsSpider) (string, error)) (string, error) {
	s, idx := p.acquire()
	defer p.release(idx)
	return fn(s)
}

func (p *jsPool) Init(ext string) error {
	p.ext = ext
	_, err := p.withSlot(func(s *jsSpider) (string, error) {
		s.ext = ext
		return "", s.Init(ext)
	})
	return err
}

func (p *jsPool) HomeContent(filter bool) (string, error) {
	return p.withSlot(func(s *jsSpider) (string, error) { return s.HomeContent(filter) })
}
func (p *jsPool) HomeVideoContent() (string, error) {
	return p.withSlot(func(s *jsSpider) (string, error) { return s.HomeVideoContent() })
}
func (p *jsPool) CategoryContent(tid, pg string, filter bool, extend map[string]string) (string, error) {
	return p.withSlot(func(s *jsSpider) (string, error) {
		return s.CategoryContent(tid, pg, filter, extend)
	})
}
func (p *jsPool) DetailContent(ids []string) (string, error) {
	return p.withSlot(func(s *jsSpider) (string, error) { return s.DetailContent(ids) })
}
func (p *jsPool) SearchContent(key string, quick bool, pg string) (string, error) {
	return p.withSlot(func(s *jsSpider) (string, error) { return s.SearchContent(key, quick, pg) })
}
func (p *jsPool) PlayerContent(flag, id string, vipFlags []string) (string, error) {
	return p.withSlot(func(s *jsSpider) (string, error) { return s.PlayerContent(flag, id, vipFlags) })
}
func (p *jsPool) LiveContent(url string) (string, error) {
	return p.withSlot(func(s *jsSpider) (string, error) { return s.LiveContent(url) })
}
func (p *jsPool) Proxy(params map[string]string) (int, string, []byte, map[string]string, error) {
	s, idx := p.acquire()
	defer p.release(idx)
	return s.Proxy(params)
}
func (p *jsPool) Action(action string) (string, error) {
	return p.withSlot(func(s *jsSpider) (string, error) { return s.Action(action) })
}
func (p *jsPool) ManualVideoCheck() (bool, error) {
	s, idx := p.acquire()
	defer p.release(idx)
	return s.ManualVideoCheck()
}
func (p *jsPool) IsVideoFormat(u string) (bool, error) {
	s, idx := p.acquire()
	defer p.release(idx)
	return s.IsVideoFormat(u)
}
func (p *jsPool) Destroy() {
	p.mu.Lock()
	slots := append([]*jsSpider(nil), p.slots...)
	p.slots = nil
	p.busy = nil
	p.mu.Unlock()
	for _, s := range slots {
		s.Destroy()
	}
}
