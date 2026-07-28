package server

import (
	"strings"
	"sync"
)

// Events HTTP 遥控事件总线，对应 ServerEvent。
type Events struct {
	mu          sync.RWMutex
	searchSubs  []chan string
	pushSubs    []chan string
	danmakuSubs []chan string
	settingSubs []chan settingEvent
	controlSubs []chan controlEvent
	refreshSubs []chan refreshEvent
	castSubs    []chan castEvent
	postMsgSubs []chan string
	// 无前端订阅时缓冲给 Flutter 轮询（否则 /postMsg 会直接丢弃）
	postMsgQ []string
}

type settingEvent struct {
	Value string
	Name  string
}

type controlEvent struct {
	Type   string
	SeekMs int64
}

type refreshEvent struct {
	Type string // subtitle / danmaku / detail / player / live
	Path string
}

type castEvent struct {
	Config  string
	Device  string
	History string
}

func NewEvents() *Events { return &Events{} }

func (e *Events) SubscribePostMsg() <-chan string { return e.subscribe(&e.postMsgSubs, 64) }

func (e *Events) SubscribeSearch() <-chan string        { return e.subscribe(&e.searchSubs, 8) }
func (e *Events) SubscribePush() <-chan string          { return e.subscribe(&e.pushSubs, 8) }
func (e *Events) SubscribeDanmaku() <-chan string       { return e.subscribe(&e.danmakuSubs, 32) }
func (e *Events) SubscribeSetting() <-chan settingEvent { return e.subscribeSetting(4) }
func (e *Events) SubscribeControl() <-chan controlEvent { return e.subscribeControl(16) }
func (e *Events) SubscribeRefresh() <-chan refreshEvent { return e.subscribeRefresh(8) }
func (e *Events) SubscribeCast() <-chan castEvent       { return e.subscribeCast(4) }

func (e *Events) subscribeSetting(cap int) <-chan settingEvent {
	e.mu.Lock()
	defer e.mu.Unlock()
	ch := make(chan settingEvent, cap)
	e.settingSubs = append(e.settingSubs, ch)
	return ch
}

func (e *Events) subscribeControl(cap int) <-chan controlEvent {
	e.mu.Lock()
	defer e.mu.Unlock()
	ch := make(chan controlEvent, cap)
	e.controlSubs = append(e.controlSubs, ch)
	return ch
}

func (e *Events) subscribeRefresh(cap int) <-chan refreshEvent {
	e.mu.Lock()
	defer e.mu.Unlock()
	ch := make(chan refreshEvent, cap)
	e.refreshSubs = append(e.refreshSubs, ch)
	return ch
}

func (e *Events) subscribeCast(cap int) <-chan castEvent {
	e.mu.Lock()
	defer e.mu.Unlock()
	ch := make(chan castEvent, cap)
	e.castSubs = append(e.castSubs, ch)
	return ch
}

func (e *Events) subscribe(subs *[]chan string, cap int) <-chan string {
	e.mu.Lock()
	defer e.mu.Unlock()
	ch := make(chan string, cap)
	*subs = append(*subs, ch)
	return ch
}

func (e *Events) EmitSearch(word string)  { e.emit(&e.searchSubs, word) }
func (e *Events) EmitPush(url string)     { e.emit(&e.pushSubs, url) }
func (e *Events) EmitDanmaku(text string) { e.emit(&e.danmakuSubs, text) }
func (e *Events) EmitSetting(cfg, name string) {
	e.emitSetting(settingEvent{Value: cfg, Name: name})
}
func (e *Events) EmitControl(typ string, seekMs int64) {
	e.emitControl(controlEvent{Type: typ, SeekMs: seekMs})
}
func (e *Events) EmitRefresh(typ, path string) {
	e.emitRefresh(refreshEvent{Type: typ, Path: path})
}
func (e *Events) EmitCast(config, device, history string) {
	e.emitCast(castEvent{Config: config, Device: device, History: history})
}
func (e *Events) EmitPostMsg(msg string) {
	msg = strings.TrimSpace(msg)
	if msg == "" {
		return
	}
	e.mu.Lock()
	hasSubs := len(e.postMsgSubs) > 0
	if !hasSubs {
		e.postMsgQ = append(e.postMsgQ, msg)
		if len(e.postMsgQ) > 64 {
			e.postMsgQ = e.postMsgQ[len(e.postMsgQ)-64:]
		}
	}
	e.mu.Unlock()
	e.emit(&e.postMsgSubs, msg)
}

// DrainPostMsg 取出并清空缓冲（供 Flutter /api/v1/ui/poll）。
func (e *Events) DrainPostMsg() []string {
	e.mu.Lock()
	defer e.mu.Unlock()
	out := e.postMsgQ
	e.postMsgQ = nil
	return out
}

func (e *Events) emitSetting(msg settingEvent) {
	e.mu.RLock()
	snapshot := append([]chan settingEvent(nil), e.settingSubs...)
	e.mu.RUnlock()
	for _, ch := range snapshot {
		select {
		case ch <- msg:
		default:
			go func(c chan settingEvent, m settingEvent) { c <- m }(ch, msg)
		}
	}
}

func (e *Events) emitControl(msg controlEvent) {
	e.mu.RLock()
	snapshot := append([]chan controlEvent(nil), e.controlSubs...)
	e.mu.RUnlock()
	for _, ch := range snapshot {
		select {
		case ch <- msg:
		default:
			go func(c chan controlEvent, m controlEvent) { c <- m }(ch, msg)
		}
	}
}

func (e *Events) emitRefresh(msg refreshEvent) {
	e.mu.RLock()
	snapshot := append([]chan refreshEvent(nil), e.refreshSubs...)
	e.mu.RUnlock()
	for _, ch := range snapshot {
		select {
		case ch <- msg:
		default:
			go func(c chan refreshEvent, m refreshEvent) { c <- m }(ch, msg)
		}
	}
}

func (e *Events) emitCast(msg castEvent) {
	e.mu.RLock()
	snapshot := append([]chan castEvent(nil), e.castSubs...)
	e.mu.RUnlock()
	for _, ch := range snapshot {
		select {
		case ch <- msg:
		default:
			go func(c chan castEvent, m castEvent) { c <- m }(ch, msg)
		}
	}
}

func (e *Events) emit(subs *[]chan string, msg string) {
	e.mu.RLock()
	snapshot := append([]chan string(nil), (*subs)...)
	e.mu.RUnlock()
	for _, ch := range snapshot {
		select {
		case ch <- msg:
		default:
			go func(c chan string, m string) { c <- m }(ch, msg)
		}
	}
}
