package server

import (
	"strings"
	"sync"
)

// Events HTTP 遥控事件总线，对应 ServerEvent。
type Events struct {
	mu          sync.RWMutex
	searchSubs  []chan searchEvent
	pushSubs    []chan string
	danmakuSubs []chan string
	settingSubs []chan settingEvent
	controlSubs []chan controlEvent
	refreshSubs []chan refreshEvent
	castSubs    []chan castEvent
	postMsgSubs []chan string
	// 按 Flutter clientId 分队列；无 clientId 的消息进 untagged（广播/兼容）。
	postMsgQ        map[string][]string
	postMsgUntagged []string
	postMsgSeen     map[string]struct{}
}

type settingEvent struct {
	Value string
	Name  string
}

type searchEvent struct {
	Word     string
	ClientID string
}

type controlEvent struct {
	Type     string
	SeekMs   int64
	ClientID string
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

func NewEvents() *Events {
	return &Events{
		postMsgQ:    map[string][]string{},
		postMsgSeen: map[string]struct{}{},
	}
}

func (e *Events) SubscribePostMsg() <-chan string { return e.subscribe(&e.postMsgSubs, 64) }

func (e *Events) SubscribeSearch() <-chan searchEvent   { return e.subscribeSearch(8) }
func (e *Events) SubscribePush() <-chan string          { return e.subscribe(&e.pushSubs, 8) }
func (e *Events) SubscribeDanmaku() <-chan string       { return e.subscribe(&e.danmakuSubs, 32) }
func (e *Events) SubscribeSetting() <-chan settingEvent { return e.subscribeSetting(4) }
func (e *Events) SubscribeControl() <-chan controlEvent { return e.subscribeControl(16) }
func (e *Events) SubscribeRefresh() <-chan refreshEvent { return e.subscribeRefresh(8) }
func (e *Events) SubscribeCast() <-chan castEvent       { return e.subscribeCast(4) }

func (e *Events) subscribeSearch(cap int) <-chan searchEvent {
	e.mu.Lock()
	defer e.mu.Unlock()
	ch := make(chan searchEvent, cap)
	e.searchSubs = append(e.searchSubs, ch)
	return ch
}

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

func (e *Events) EmitSearch(word, clientID string) {
	e.emitSearch(searchEvent{Word: word, ClientID: strings.TrimSpace(clientID)})
}
func (e *Events) EmitPush(url string)     { e.emit(&e.pushSubs, url) }
func (e *Events) EmitDanmaku(text string) { e.emit(&e.danmakuSubs, text) }
func (e *Events) EmitSetting(cfg, name string) {
	e.emitSetting(settingEvent{Value: cfg, Name: name})
}
func (e *Events) EmitControl(typ string, seekMs int64, clientID string) {
	e.emitControl(controlEvent{Type: typ, SeekMs: seekMs, ClientID: strings.TrimSpace(clientID)})
}
func (e *Events) EmitRefresh(typ, path string) {
	e.emitRefresh(refreshEvent{Type: typ, Path: path})
}
func (e *Events) EmitCast(config, device, history string) {
	e.emitCast(castEvent{Config: config, Device: device, History: history})
}

// EmitPostMsg 无目标客户端时入 untagged / 广播（兼容旧 JAR）。
func (e *Events) EmitPostMsg(msg string) {
	e.EmitPostMsgTo(msg, "")
}

// EmitPostMsgTo 将消息投递到指定 clientId 的队列；clientId 为空则广播给已知客户端。
func (e *Events) EmitPostMsgTo(msg, clientID string) {
	msg = strings.TrimSpace(msg)
	if msg == "" {
		return
	}
	clientID = strings.TrimSpace(clientID)
	e.mu.Lock()
	hasSubs := len(e.postMsgSubs) > 0
	if !hasSubs {
		if clientID != "" {
			e.appendClientLocked(clientID, msg)
		} else if len(e.postMsgSeen) == 0 {
			e.postMsgUntagged = append(e.postMsgUntagged, msg)
			e.trimUntaggedLocked()
		} else {
			for cid := range e.postMsgSeen {
				e.appendClientLocked(cid, msg)
			}
		}
	}
	e.mu.Unlock()
	e.emit(&e.postMsgSubs, msg)
}

func (e *Events) appendClientLocked(clientID, msg string) {
	if e.postMsgQ == nil {
		e.postMsgQ = map[string][]string{}
	}
	q := append(e.postMsgQ[clientID], msg)
	if len(q) > 64 {
		q = q[len(q)-64:]
	}
	e.postMsgQ[clientID] = q
}

func (e *Events) trimUntaggedLocked() {
	if len(e.postMsgUntagged) > 64 {
		e.postMsgUntagged = e.postMsgUntagged[len(e.postMsgUntagged)-64:]
	}
}

// DrainPostMsg 取出并清空指定客户端缓冲（供 Flutter /api/v1/ui/poll）。
// clientID 为空时只取 untagged（旧客户端兼容）。
func (e *Events) DrainPostMsg(clientID string) []string {
	e.mu.Lock()
	defer e.mu.Unlock()
	clientID = strings.TrimSpace(clientID)
	if clientID == "" {
		out := e.postMsgUntagged
		e.postMsgUntagged = nil
		return out
	}
	if e.postMsgSeen == nil {
		e.postMsgSeen = map[string]struct{}{}
	}
	e.postMsgSeen[clientID] = struct{}{}
	out := e.postMsgQ[clientID]
	delete(e.postMsgQ, clientID)
	if len(e.postMsgUntagged) > 0 {
		out = append(append([]string{}, e.postMsgUntagged...), out...)
		e.postMsgUntagged = nil
	}
	return out
}

func (e *Events) emitSearch(msg searchEvent) {
	e.mu.RLock()
	snapshot := append([]chan searchEvent(nil), e.searchSubs...)
	e.mu.RUnlock()
	for _, ch := range snapshot {
		select {
		case ch <- msg:
		default:
			go func(c chan searchEvent, m searchEvent) { c <- m }(ch, msg)
		}
	}
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
