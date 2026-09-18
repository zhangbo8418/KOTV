package remote

import (
	"strings"
	"sync"
)

// Queue 供无本地桌面 UI 的 headless 引擎（Flutter）轮询遥控指令。
// 按 ScopeID（优先 userId）分桶，避免多用户轮询时互相抢走指令。
type Queue struct {
	mu       sync.Mutex
	byClient map[string]*clientBucket
	known    map[string]struct{} // 曾 Drain 过的客户端（用于无目标时广播）
}

type clientBucket struct {
	ctrl     []ControlCmd
	srch     []string
	refresh  []RefreshCmd
	danmaku  []string
}

type ControlCmd struct {
	Type   string `json:"type"`
	SeekMs int64  `json:"seekMs"`
}

// RefreshCmd 遥控推字幕/弹幕文件：Type=subtitle|danmaku，Path 为本地路径或 URL。
type RefreshCmd struct {
	Type string `json:"type"`
	Path string `json:"path"`
}

var DefaultQueue = &Queue{
	byClient: map[string]*clientBucket{},
	known:    map[string]struct{}{},
}

func (q *Queue) bucketLocked(id string) *clientBucket {
	if q.byClient == nil {
		q.byClient = map[string]*clientBucket{}
	}
	b := q.byClient[id]
	if b == nil {
		b = &clientBucket{}
		q.byClient[id] = b
	}
	return b
}

func (q *Queue) targetsLocked(clientID string) []string {
	clientID = strings.TrimSpace(clientID)
	if clientID != "" {
		return []string{clientID}
	}
	// 无目标：广播给已知客户端 + 空桶（桌面/旧客户端兼容）
	out := make([]string, 0, len(q.known)+1)
	out = append(out, "")
	for id := range q.known {
		if id != "" {
			out = append(out, id)
		}
	}
	return out
}

func (q *Queue) PushControl(typ string, seekMs int64, clientID string) {
	q.mu.Lock()
	defer q.mu.Unlock()
	for _, id := range q.targetsLocked(clientID) {
		b := q.bucketLocked(id)
		b.ctrl = append(b.ctrl, ControlCmd{Type: typ, SeekMs: seekMs})
		if len(b.ctrl) > 64 {
			b.ctrl = b.ctrl[len(b.ctrl)-64:]
		}
	}
}

func (q *Queue) PushSearch(keyword, clientID string) {
	if keyword == "" {
		return
	}
	q.mu.Lock()
	defer q.mu.Unlock()
	for _, id := range q.targetsLocked(clientID) {
		b := q.bucketLocked(id)
		b.srch = append(b.srch, keyword)
		if len(b.srch) > 16 {
			b.srch = b.srch[len(b.srch)-16:]
		}
	}
}

func (q *Queue) PushRefresh(typ, path, clientID string) {
	typ = strings.ToLower(strings.TrimSpace(typ))
	path = strings.TrimSpace(path)
	if typ == "" || path == "" {
		return
	}
	q.mu.Lock()
	defer q.mu.Unlock()
	for _, id := range q.targetsLocked(clientID) {
		b := q.bucketLocked(id)
		b.refresh = append(b.refresh, RefreshCmd{Type: typ, Path: path})
		if len(b.refresh) > 16 {
			b.refresh = b.refresh[len(b.refresh)-16:]
		}
	}
}

func (q *Queue) PushLiveDanmaku(text, clientID string) {
	text = strings.TrimSpace(text)
	if text == "" {
		return
	}
	q.mu.Lock()
	defer q.mu.Unlock()
	for _, id := range q.targetsLocked(clientID) {
		b := q.bucketLocked(id)
		b.danmaku = append(b.danmaku, text)
		if len(b.danmaku) > 64 {
			b.danmaku = b.danmaku[len(b.danmaku)-64:]
		}
	}
}

// Drain 取出并清空指定客户端缓冲；同时登记为已知客户端以便后续广播。
func (q *Queue) Drain(clientID string) (controls []ControlCmd, searches []string, refreshes []RefreshCmd, danmaku []string) {
	clientID = strings.TrimSpace(clientID)
	q.mu.Lock()
	defer q.mu.Unlock()
	q.rememberLocked(clientID)
	b := q.byClient[clientID]
	if b == nil {
		return nil, nil, nil, nil
	}
	controls = b.ctrl
	searches = b.srch
	refreshes = b.refresh
	danmaku = b.danmaku
	b.ctrl = nil
	b.srch = nil
	b.refresh = nil
	b.danmaku = nil
	return
}

// Remember 登记在线客户端（上报媒体态时也调用，便于无目标广播）。
func (q *Queue) Remember(clientID string) {
	clientID = strings.TrimSpace(clientID)
	if clientID == "" {
		return
	}
	q.mu.Lock()
	defer q.mu.Unlock()
	q.rememberLocked(clientID)
}

func (q *Queue) rememberLocked(clientID string) {
	if q.known == nil {
		q.known = map[string]struct{}{}
	}
	if clientID != "" {
		q.known[clientID] = struct{}{}
	}
}

// WireFlutterBridge 在无本地桌面 UI 时把遥控指令写入队列，供 Flutter 轮询。
func WireFlutterBridge() {
	SetHandlers(Handlers{
		OnSearch: func(keyword, clientID string) {
			DefaultQueue.PushSearch(keyword, clientID)
		},
		OnPush: func() {},
		OnControl: func(typ string, seekMs int64, clientID string) {
			DefaultQueue.PushControl(typ, seekMs, clientID)
		},
		MediaState: SnapshotMediaFromStore,
	})
}
