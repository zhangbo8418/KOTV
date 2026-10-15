package settings

import (
	"strings"

	"github.com/bobo/KOTV/internal/hostclient"
)

// 远端租户按「用户 + 前端平台」隔离的设置键（播放器等与客户端能力相关）。
// 存 setting 表：id = p:<platform>:<key>，owner = DataOwner()。
var clientProfileKeys = map[Type]bool{
	Player:             true,
	PlayerLive:         true,
	PlayerSpeed:        true,
	PlayerScale:        true,
	PlayerDecode:       true,
	PlayerRender:       true,
	PlayerFailover:     true,
	PlayerVolume:       true,
	PlayerAmbient:      true,
	PlayerStableVolume: true,
	UA:                 true,
	MpvVulkan:          true,
	MpvGpuNext:         true,
	MpvConf:            true,
}

func platformSettingID(platform, key string) string {
	return "p:" + normalizePlatform(platform) + ":" + key
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

// OverlayClientProfile 按「用户+前端平台」覆盖播放器等键，并按前端能力钳制选项。
func OverlayClientProfile(vals map[string]string, platform string) {
	if vals == nil {
		return
	}
	platform = normalizePlatform(platform)
	uid := hostclient.DataOwner()
	if uid != "" && storeDB != nil {
		for t := range clientProfileKeys {
			id := platformSettingID(platform, string(t))
			if v, ok, err := storeDB.GetSetting(uid, id); err == nil && ok {
				vals[string(t)] = v
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

// SetClientProfileKeys 远端租户写入平台画像；返回仍应写普通 setting 的键。
func SetClientProfileKeys(kv map[string]string, platform string) map[string]string {
	uid := hostclient.DataOwner()
	if uid == "" || storeDB == nil {
		return kv
	}
	platform = normalizePlatform(platform)
	rest := map[string]string{}
	for k, v := range kv {
		t := Type(k)
		if clientProfileKeys[t] {
			_ = storeDB.SetSetting(uid, platformSettingID(platform, k), v)
			continue
		}
		rest[k] = v
	}
	return rest
}
