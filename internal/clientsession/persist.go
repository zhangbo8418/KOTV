package clientsession

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"sync"

	"github.com/bobo/KOTV/internal/paths"
)

// 按 clientId 持久化上次点播源，引擎重启后可恢复。
type persisted struct {
	Source string `json:"source"`
	Home   string `json:"home,omitempty"`
}

var (
	persistMu sync.Mutex
	persist   map[string]persisted
)

func persistPath() string {
	return filepath.Join(paths.Data(), "client_sessions.json")
}

func loadPersistLocked() {
	if persist != nil {
		return
	}
	persist = map[string]persisted{}
	b, err := os.ReadFile(persistPath())
	if err != nil || len(b) == 0 {
		return
	}
	_ = json.Unmarshal(b, &persist)
}

func savePersistLocked() {
	if persist == nil {
		persist = map[string]persisted{}
	}
	b, err := json.MarshalIndent(persist, "", "  ")
	if err != nil {
		return
	}
	_ = os.MkdirAll(filepath.Dir(persistPath()), 0o755)
	_ = os.WriteFile(persistPath(), b, 0o644)
}

// SaveSource 记住该客户端上次成功加载的点播源与首页。
func SaveSource(clientID, source, home string) {
	clientID = strings.TrimSpace(clientID)
	source = strings.TrimSpace(source)
	if clientID == "" || source == "" {
		return
	}
	persistMu.Lock()
	defer persistMu.Unlock()
	loadPersistLocked()
	persist[clientID] = persisted{Source: source, Home: strings.TrimSpace(home)}
	savePersistLocked()
}

// LoadSource 读取该客户端上次点播源（无则空）。
func LoadSource(clientID string) (source, home string) {
	clientID = strings.TrimSpace(clientID)
	if clientID == "" {
		return "", ""
	}
	persistMu.Lock()
	defer persistMu.Unlock()
	loadPersistLocked()
	p := persist[clientID]
	return p.Source, p.Home
}
