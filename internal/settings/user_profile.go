package settings

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"sync"

	"github.com/bobo/KOTV/internal/hostclient"
	"github.com/bobo/KOTV/internal/paths"
)

// 远端租户按「用户 + 前端平台」隔离的设置键（播放器等与客户端能力相关）。
var clientProfileKeys = map[Type]bool{
	Player:             true,
	PlayerLive:         true,
	PlayerSpeed:        true,
	PlayerScale:        true,
	PlayerDecode:       true,
	PlayerFailover:     true,
	PlayerVolume:       true,
	PlayerAmbient:      true,
	PlayerStableVolume: true,
	UA:                 true,
	MpvVulkan:          true,
	MpvGpuNext:         true,
	MpvConf:            true,
}

var userProfMu sync.Mutex

type userClientProfiles struct {
	Profiles map[string]map[string]string `json:"profiles"` // platform -> key -> value
}

func userProfilePath(userID string) string {
	return filepath.Join(paths.Data(), "users", userID, "client_settings.json")
}

func loadUserProfiles(userID string) userClientProfiles {
	b, err := os.ReadFile(userProfilePath(userID))
	if err != nil {
		return userClientProfiles{Profiles: map[string]map[string]string{}}
	}
	var p userClientProfiles
	if json.Unmarshal(b, &p) != nil || p.Profiles == nil {
		return userClientProfiles{Profiles: map[string]map[string]string{}}
	}
	return p
}

func saveUserProfiles(userID string, p userClientProfiles) error {
	dir := filepath.Dir(userProfilePath(userID))
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	b, err := json.MarshalIndent(p, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(userProfilePath(userID), b, 0o644)
}

func normalizePlatform(p string) string {
	p = strings.ToLower(strings.TrimSpace(p))
	switch p {
	case "android", "ios", "windows", "macos", "linux", "web":
		return p
	default:
		if p == "" {
			return "unknown"
		}
		return p
	}
}

// OverlayClientProfile 按「用户+前端平台」覆盖播放器等键，并按前端能力钳制选项
//（手机不落 PC 外置播放器；PC 不落安卓的 Exo；Web 仅 HTML5/video_player）。
func OverlayClientProfile(vals map[string]string, platform string) {
	if vals == nil {
		return
	}
	platform = normalizePlatform(platform)
	uid := hostclient.RuntimeUserID()
	if uid != "" {
		userProfMu.Lock()
		p := loadUserProfiles(uid)
		prof := p.Profiles[platform]
		userProfMu.Unlock()
		if prof != nil {
			for k, v := range prof {
				vals[k] = v
			}
		}
	}
	clampPlayerKeysForPlatform(vals, platform)
}

func clampPlayerKeysForPlatform(vals map[string]string, platform string) {
	vals[string(Player)] = strings.TrimSpace(vals[string(Player)])
	vals[string(PlayerLive)] = strings.TrimSpace(vals[string(PlayerLive)])
	switch platform {
	case "android":
		vals[string(Player)] = clampListedPlayer(vals[string(Player)], "innie#exo",
			"innie#exo", "innie#mpv", "innie#fvp")
		vals[string(PlayerLive)] = clampListedPlayer(vals[string(PlayerLive)], "innie#exo",
			"innie#exo", "innie#mpv", "innie#fvp")
	case "windows":
		vals[string(Player)] = clampListedPlayer(vals[string(Player)], "innie#mpv",
			"innie#mpv", "innie#fvp", "outie#mpv", "outie#vlc", "outie#iina")
		vals[string(PlayerLive)] = clampListedPlayer(vals[string(PlayerLive)], "innie#mpv",
			"innie#mpv", "innie#fvp", "outie#mpv", "outie#vlc", "outie#iina")
	case "macos", "linux":
		vals[string(Player)] = clampListedPlayer(vals[string(Player)], "innie#mpv",
			"innie#mpv", "innie#fvp", "outie#mpv", "outie#vlc", "outie#iina")
		vals[string(PlayerLive)] = clampListedPlayer(vals[string(PlayerLive)], "innie#mpv",
			"innie#mpv", "innie#fvp", "outie#mpv", "outie#vlc", "outie#iina")
	case "ios":
		vals[string(Player)] = clampListedPlayer(vals[string(Player)], "innie#mpv",
			"innie#mpv", "innie#fvp", "innie#html")
		vals[string(PlayerLive)] = clampListedPlayer(vals[string(PlayerLive)], "innie#mpv",
			"innie#mpv", "innie#fvp", "innie#html")
	case "web":
		vals[string(Player)] = clampListedPlayer(vals[string(Player)], "innie#html",
			"innie#html", "innie#art", "innie#xg", "innie#zw")
		vals[string(PlayerLive)] = clampListedPlayer(vals[string(PlayerLive)], "innie#html",
			"innie#html", "innie#art", "innie#xg", "innie#zw")
	}
}

func clampListedPlayer(v, def string, allowed ...string) string {
	v = strings.TrimSpace(v)
	for _, a := range allowed {
		if v == a {
			return v
		}
	}
	return def
}

// SetClientProfileKeys 远端租户写入前端平台画像；返回仍应写全局 setting.ini 的键。
func SetClientProfileKeys(kv map[string]string, platform string) map[string]string {
	uid := hostclient.RuntimeUserID()
	if uid == "" {
		return kv
	}
	platform = normalizePlatform(platform)
	rest := map[string]string{}
	userProfMu.Lock()
	defer userProfMu.Unlock()
	p := loadUserProfiles(uid)
	if p.Profiles == nil {
		p.Profiles = map[string]map[string]string{}
	}
	prof := p.Profiles[platform]
	if prof == nil {
		prof = map[string]string{}
		p.Profiles[platform] = prof
	}
	changed := false
	for k, v := range kv {
		t := Type(k)
		if clientProfileKeys[t] {
			prof[k] = v
			changed = true
			continue
		}
		rest[k] = v
	}
	if changed {
		_ = saveUserProfiles(uid, p)
	}
	return rest
}
