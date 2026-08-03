package spider

import (
	"sync"
)

// pyPool 同站 Python 进程池：每个 slot 一个常驻 pySpider，多用户可并行打同一站。
type pyPool struct {
	key, api, ext, jar string

	mu      sync.Mutex
	slots   []*pySpider
	max     int
	waiters []chan struct{}
	busy    []bool
}

func newPyPool(key, api, ext, jar string) *pyPool {
	return &pyPool{key: key, api: api, ext: ext, jar: jar, max: scriptPoolSize()}
}

func (p *pyPool) acquire() (*pySpider, int) {
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
	s := &pySpider{key: p.key, api: p.api, ext: p.ext, jar: p.jar, sessionSlot: len(p.slots)}
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

func (p *pyPool) release(idx int) {
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

func (p *pyPool) matchesClient(clientID string) bool {
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

func (p *pyPool) interrupt() {
	p.mu.Lock()
	slots := append([]*pySpider(nil), p.slots...)
	p.mu.Unlock()
	for _, s := range slots {
		s.interrupt()
	}
}

func (p *pyPool) withSlot(fn func(s *pySpider, slot int) (string, error)) (string, error) {
	s, idx := p.acquire()
	defer p.release(idx)
	return fn(s, idx)
}

func (p *pyPool) Init(ext string) error {
	p.ext = ext
	_, err := p.withSlot(func(s *pySpider, _ int) (string, error) {
		s.ext = ext
		return "", s.Init(ext)
	})
	return err
}

func (p *pyPool) HomeContent(filter bool) (string, error) {
	return p.withSlot(func(s *pySpider, _ int) (string, error) { return s.HomeContent(filter) })
}
func (p *pyPool) HomeVideoContent() (string, error) {
	return p.withSlot(func(s *pySpider, _ int) (string, error) { return s.HomeVideoContent() })
}
func (p *pyPool) CategoryContent(tid, pg string, filter bool, extend map[string]string) (string, error) {
	return p.withSlot(func(s *pySpider, _ int) (string, error) {
		return s.CategoryContent(tid, pg, filter, extend)
	})
}
func (p *pyPool) DetailContent(ids []string) (string, error) {
	return p.withSlot(func(s *pySpider, _ int) (string, error) { return s.DetailContent(ids) })
}
func (p *pyPool) SearchContent(key string, quick bool, pg string) (string, error) {
	return p.withSlot(func(s *pySpider, _ int) (string, error) { return s.SearchContent(key, quick, pg) })
}
func (p *pyPool) PlayerContent(flag, id string, vipFlags []string) (string, error) {
	return p.withSlot(func(s *pySpider, _ int) (string, error) {
		return s.PlayerContent(flag, id, vipFlags)
	})
}
func (p *pyPool) LiveContent(url string) (string, error) {
	return p.withSlot(func(s *pySpider, _ int) (string, error) { return s.LiveContent(url) })
}
func (p *pyPool) Proxy(params map[string]string) (int, string, []byte, map[string]string, error) {
	s, idx := p.acquire()
	defer p.release(idx)
	return s.Proxy(params)
}
func (p *pyPool) Action(action string) (string, error) {
	return p.withSlot(func(s *pySpider, _ int) (string, error) { return s.Action(action) })
}
func (p *pyPool) ManualVideoCheck() (bool, error) {
	s, idx := p.acquire()
	defer p.release(idx)
	return s.ManualVideoCheck()
}
func (p *pyPool) IsVideoFormat(u string) (bool, error) {
	s, idx := p.acquire()
	defer p.release(idx)
	return s.IsVideoFormat(u)
}
func (p *pyPool) Destroy() {
	p.mu.Lock()
	slots := append([]*pySpider(nil), p.slots...)
	p.slots = nil
	p.busy = nil
	p.mu.Unlock()
	for _, s := range slots {
		s.Destroy()
	}
}
