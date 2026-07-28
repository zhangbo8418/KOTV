package remote

import "sync"

// Queue 供无本地桌面 UI 的 headless 引擎（Flutter）轮询遥控指令。
type Queue struct {
	mu   sync.Mutex
	ctrl []ControlCmd
	srch []string
}

type ControlCmd struct {
	Type   string `json:"type"`
	SeekMs int64  `json:"seekMs"`
}

var DefaultQueue = &Queue{}

func (q *Queue) PushControl(typ string, seekMs int64) {
	q.mu.Lock()
	defer q.mu.Unlock()
	q.ctrl = append(q.ctrl, ControlCmd{Type: typ, SeekMs: seekMs})
	if len(q.ctrl) > 64 {
		q.ctrl = q.ctrl[len(q.ctrl)-64:]
	}
}

func (q *Queue) PushSearch(keyword string) {
	if keyword == "" {
		return
	}
	q.mu.Lock()
	defer q.mu.Unlock()
	q.srch = append(q.srch, keyword)
	if len(q.srch) > 16 {
		q.srch = q.srch[len(q.srch)-16:]
	}
}

func (q *Queue) Drain() (controls []ControlCmd, searches []string) {
	q.mu.Lock()
	defer q.mu.Unlock()
	controls = q.ctrl
	searches = q.srch
	q.ctrl = nil
	q.srch = nil
	return
}

// WireFlutterBridge 在无本地桌面 UI 时把遥控指令写入队列，供 Flutter 轮询。
func WireFlutterBridge() {
	SetHandlers(Handlers{
		OnSearch: func(keyword string) {
			DefaultQueue.PushSearch(keyword)
		},
		OnPush: func() {},
		OnControl: func(typ string, seekMs int64) {
			DefaultQueue.PushControl(typ, seekMs)
		},
		MediaState: SnapshotMediaFromStore,
	})
}
