package settings

import (
	"crypto/rand"
	"encoding/json"
	"fmt"
	"math/big"
	"runtime"
	"strings"
	"sync"

	"github.com/bobo/KOTV/internal/database"
	"github.com/bobo/KOTV/internal/hostclient"
	"github.com/bobo/KOTV/internal/util"
)

// Type 设置项类型。
type Type string

const (
	VOD                Type = "vod"
	Home               Type = "home" // 当前首页站 key
	LIVE               Type = "live"
	LOG                Type = "log"
	Player             Type = "player"     // 点播播放器
	PlayerLive         Type = "playerLive" // 直播播放器（与点播独立）
	Proxy              Type = "proxy"
	Theme              Type = "theme"
	AdFilter           Type = "adFilter"
	M3U8Cfg            Type = "m3u8FilterConfig"
	DanmakuOn          Type = "danmaku"
	DanmakuAPI         Type = "danmakuApi"
	DanmakuSize        Type = "danmakuSize"
	DanmakuOpacity     Type = "danmakuOpacity"
	DanmakuRows        Type = "danmakuRows"
	AssrtToken         Type = "assrtToken"
	PreferredParse     Type = "preferredParse"
	PlayerSpeed        Type = "playerSpeed"
	PlayerScale        Type = "playerScale"
	PlayerDecode       Type = "playerDecode"
	PlayerRender       Type = "playerRender"   // 渲染方式：surface | texture
	PlayerFailover     Type = "playerFailover" // 黑屏/停滞自动切换播放器：auto | off
	PlayerVolume       Type = "playerVolume"
	PlayerAmbient      Type = "playerAmbient"
	PlayerStableVolume Type = "playerStableVolume"
	UA                 Type = "ua" // 播放 User-Agent；空则用 Media3 默认
	// MPV：mpv_vulkan / mpv_gpu_next + 自定义 mpv.conf
	MpvVulkan    Type = "mpvVulkan"
	MpvGpuNext   Type = "mpvGpuNext"
	MpvConf      Type = "mpvConf"
	LiveKeep     Type = "liveKeep"     // 上次直播：源$$$分组$$$频道$$$线路URL
	LiveAcross   Type = "liveAcross"   // 跨分组换台，默认 true
	LiveChange   Type = "liveChange"   // 播放失败自动换线，默认 true
	LiveInvert   Type = "liveInvert"   // 反转上下换台方向，默认 false
	DLNARenderer Type = "dlnaRenderer" // 作为 DLNA 被投端，默认 false
	UpdateURL    Type = "updateUrl"
	AvatarPath   Type = "avatarPath"
	WallMode     Type = "wallMode"
	WallURL      Type = "wallURL"
	WallFile     Type = "wallFile"
	Incognito    Type = "incognito"
	SyncPairCode Type = "syncPairCode"
	DeviceUUID   Type = "deviceUUID"
	// SyncHistoryPending / SyncKeepPending：同步接收后待客户端落 SP 的 JSON。
	SyncHistoryPending Type = "kotv_sync_history"
	SyncKeepPending    Type = "kotv_sync_keep"
	RemoteAuth         Type = "remoteAuth"    // 允许非本机连入并强制登录，默认 false
	AllowRegister      Type = "allowRegister" // 开放注册，默认 false

	// 播放细项（须进 APIGetSettings 白名单，否则冷启动丢设置）。
	AudioPassThrough         Type = "audioPassThrough"
	ExoDiskCache             Type = "exoDiskCache"
	ExoAdblock               Type = "exoAdblock"
	ExoTunneling             Type = "exoTunneling"
	ExoPreferAac             Type = "exoPreferAac"
	ExoSkipSilence           Type = "exoSkipSilence"
	ExoSoftAudioPrefer       Type = "exoSoftAudioPrefer"
	ExoSoftVideoPrefer       Type = "exoSoftVideoPrefer"
	ExoBuffer                Type = "exoBuffer"
	ExoLibass                Type = "exoLibass"
	ExoSecondarySubtitle     Type = "exoSecondarySubtitle"
	ExoDolbyVision           Type = "exoDolbyVision"
	ExoPreferredTextLangs    Type = "exoPreferredTextLangs"
	ExoDiskPreloadMs         Type = "exoDiskPreloadMs"
	MpvTlsVerify             Type = "mpvTlsVerify"
	MpvDiskCache             Type = "mpvDiskCache"
	MpvGpuApi                Type = "mpvGpuApi"
	VideoEq                  Type = "videoEq"
	AudioEq                  Type = "audioEq"
	VideoBrightness          Type = "videoBrightness"
	VideoContrast            Type = "videoContrast"
	VideoSaturation          Type = "videoSaturation"
	VideoGamma               Type = "videoGamma"
	VideoHue                 Type = "videoHue"
	VideoTemperature         Type = "videoTemperature"
	VideoSharpness           Type = "videoSharpness"
	VideoShadow              Type = "videoShadow"
	PreloadNextEpisode       Type = "preloadNextEpisode"
	SubtitleFontScale        Type = "subtitleFontScale"
	SubtitlePos              Type = "subtitlePos"
	SubtitleColor            Type = "subtitleColor"
	SubtitleBorderColor      Type = "subtitleBorderColor"
	SubtitleBorderSize       Type = "subtitleBorderSize"
	SubtitleSecondaryPos     Type = "subtitleSecondaryPos"
	SubtitleBgColor          Type = "subtitleBgColor"
	AudioEqBands             Type = "audioEqBands"
	AudioDialogue            Type = "audioDialogue"
	AudioBalance             Type = "audioBalance"
	DanmakuOffsetMs          Type = "danmakuOffsetMs"
	SubtitleStyleMode        Type = "subtitleStyleMode"
	SubtitleEdgeType         Type = "subtitleEdgeType"
	SubtitleTextOpacity      Type = "subtitleTextOpacity"
	SubtitleBgOpacity        Type = "subtitleBgOpacity"
	SubtitleEdgeOpacity      Type = "subtitleEdgeOpacity"
	SubtitleOffsetMs         Type = "subtitleOffsetMs"
	SubtitleShadowStrength   Type = "subtitleShadowStrength"
	SubtitleFont             Type = "subtitleFont"
	SubtitleFontPath         Type = "subtitleFontPath"
	PlayerScaleLive          Type = "playerScaleLive"
	PlayerBackground         Type = "playerBackground"
	PlayerSpeedLongPress     Type = "playerSpeedLongPress"
	DanmakuLoad              Type = "danmakuLoad"
	DanmakuAuto              Type = "danmakuAuto"
	DanmakuSpiderFirst       Type = "danmakuSpiderFirst"
	DanmakuShowScroll        Type = "danmakuShowScroll"
	DanmakuShowTop           Type = "danmakuShowTop"
	DanmakuShowBottom        Type = "danmakuShowBottom"
	DanmakuShowReverse       Type = "danmakuShowReverse"
	DanmakuShowSpecial       Type = "danmakuShowSpecial"
	DanmakuShowPositioned    Type = "danmakuShowPositioned"
	DanmakuFixedDurationMs   Type = "danmakuFixedDurationMs"
	DanmakuStrokeMode        Type = "danmakuStrokeMode"
	DanmakuColorMode         Type = "danmakuColorMode"
	DanmakuFont              Type = "danmakuFont"
	DanmakuRowsTop           Type = "danmakuRowsTop"
	DanmakuRowsBottom        Type = "danmakuRowsBottom"
	DanmakuMaxOnScreen       Type = "danmakuMaxOnScreen"
	DanmakuScrollArea        Type = "danmakuScrollArea"
	DanmakuScrollGap         Type = "danmakuScrollGap"
	DanmakuShadowOpacity     Type = "danmakuShadowOpacity"
	DanmakuDurationMs        Type = "danmakuDurationMs"
	DanmakuLineSpacing       Type = "danmakuLineSpacing"
	DanmakuBold              Type = "danmakuBold"
	DanmakuStrokeWidth       Type = "danmakuStrokeWidth"
	DanmakuProjectionOffsetX Type = "danmakuProjectionOffsetX"
	DanmakuProjectionOffsetY Type = "danmakuProjectionOffsetY"
	DanmakuProjectionOpacity Type = "danmakuProjectionOpacity"
	AudioChannelMode         Type = "audioChannelMode"
	AudioStability           Type = "audioStability"
	AudioBoost               Type = "audioBoost"
	AudioPreamp              Type = "audioPreamp"
	AudioLoudness            Type = "audioLoudness"
	AudioCenterGain          Type = "audioCenterGain"
	AudioOffsetMs            Type = "audioOffsetMs"
	PlayerSkipOpeningEnding  Type = "playerSkipOpeningEnding"
	BootLive                 Type = "bootLive"
	ExoDiskPreloadThreads    Type = "exoDiskPreloadThreads"
	ExoDiskPreloadSizeMb     Type = "exoDiskPreloadSizeMb"
	// Language：UI/系统语言提示（如 zh-Hant）；TransEnabled 用。
	Language Type = "language"
	// SearchZhuyin 横屏搜索键盘用注音。
	SearchZhuyin Type = "searchZhuyin"
)

type item struct {
	ID    string `json:"id"`
	Label string `json:"label"`
	Value string `json:"value"`
}

type file struct {
	List  []item                     `json:"list"`
	Cache map[string]json.RawMessage `json:"cache"`
}

var (
	mu      sync.RWMutex
	data    = defaultFile()
	storeDB *database.DB
)

// BindDB 设置持久化到 SQLite（须在 Load 前调用）。
func BindDB(db *database.DB) { storeDB = db }

func isHostOnly(t Type) bool {
	switch t {
	case RemoteAuth, AllowRegister, DeviceUUID, SyncPairCode, UpdateURL, LOG, DLNARenderer:
		return true
	default:
		return false
	}
}

// resolveOwner 本机/宿主机键 → ''；远端用户偏好 → userId。
func resolveOwner(t Type) string {
	if isHostOnly(t) {
		return ""
	}
	return hostclient.DataOwner()
}

func persistDB(owner, id, value string) {
	if storeDB == nil || id == "" {
		return
	}
	_ = storeDB.SetSetting(owner, id, value)
}

func defaultFile() file {
	return file{
		List: []item{
			{ID: "vod", Label: "点播", Value: ""},
			{ID: "home", Label: "首页站", Value: ""},
			{ID: "live", Label: "直播", Value: ""},
			{ID: "log", Label: "日志级别", Value: "info"},
			{ID: "player", Label: "点播播放器", Value: defaultVodPlayerValue()},
			{ID: "playerLive", Label: "直播播放器", Value: defaultLivePlayerValue()},
			{ID: "proxy", Label: "代理", Value: "false#"}, // false#=关；true#URL=开（界面不展示该串）
			{ID: "theme", Label: "主题", Value: "system"},
			{ID: "adFilter", Label: "M3U8广告过滤", Value: "true"},
			{ID: "m3u8FilterConfig", Label: "M3U8过滤配置(smart|mild)", Value: "{\"mode\":\"smart\"}"},
			{ID: "danmaku", Label: "弹幕", Value: "true"},
			{ID: "danmakuApi", Label: "弹幕API", Value: ""},
			{ID: "danmakuSize", Label: "弹幕字号", Value: "18"},
			{ID: "danmakuOpacity", Label: "弹幕透明度", Value: "85"},
			{ID: "danmakuRows", Label: "弹幕行数", Value: "6"},
			{ID: "assrtToken", Label: "Assrt字幕Token", Value: ""},
			{ID: "playerSpeed", Label: "默认倍速", Value: "1.0"},
			{ID: "playerScale", Label: "画面比例", Value: "default"},
			{ID: "playerDecode", Label: "解码方式", Value: "auto"},
			{ID: "playerRender", Label: "渲染方式", Value: "surface"},
			{ID: "playerFailover", Label: "自动切换播放器", Value: "auto"},
			{ID: "playerVolume", Label: "默认音量", Value: "80"},
			{ID: "playerAmbient", Label: "氛围模式", Value: "false"},
			{ID: "playerStableVolume", Label: "稳定音量", Value: "false"},
			{ID: "ua", Label: "User-Agent", Value: ""},
			{ID: "mpvVulkan", Label: "MPV Vulkan", Value: "false"},
			{ID: "mpvGpuNext", Label: "MPV gpu-next", Value: "false"},
			{ID: "mpvConf", Label: "MPV 配置", Value: ""},
			{ID: "liveKeep", Label: "上次直播", Value: ""},
			{ID: "liveAcross", Label: "跨组换台", Value: "true"},
			{ID: "liveChange", Label: "失败换线", Value: "true"},
			{ID: "liveInvert", Label: "反转换台", Value: "false"},
			{ID: "dlnaRenderer", Label: "DLNA被投端", Value: "false"},
			{ID: "updateUrl", Label: "更新地址", Value: ""},
			{ID: "avatarPath", Label: "头像", Value: ""},
			{ID: "wallMode", Label: "壁纸模式", Value: "config"},
			{ID: "wallURL", Label: "壁纸 URL", Value: ""},
			{ID: "wallFile", Label: "壁纸文件", Value: ""},
			{ID: "incognito", Label: "无痕模式", Value: "false"},
			{ID: "syncPairCode", Label: "同步配对码", Value: ""},
			{ID: "deviceUUID", Label: "设备标识", Value: ""},
			{ID: "remoteAuth", Label: "远端鉴权", Value: "false"},
			{ID: "allowRegister", Label: "开放注册", Value: "false"},
			{ID: "audioPassThrough", Label: "音频直通", Value: "true"},
			{ID: "exoDiskCache", Label: "Exo磁盘缓存", Value: "false"},
			{ID: "exoAdblock", Label: "Exo去广告", Value: "true"},
			{ID: "exoTunneling", Label: "Exo隧道", Value: "false"},
			{ID: "exoPreferAac", Label: "Exo优先AAC", Value: "false"},
			{ID: "exoSkipSilence", Label: "Exo跳过静音", Value: "false"},
			{ID: "exoSoftAudioPrefer", Label: "Exo软解音频优先", Value: "false"},
			{ID: "exoSoftVideoPrefer", Label: "Exo软解视频优先", Value: "false"},
			{ID: "exoBuffer", Label: "Exo缓冲倍率", Value: "1"},
			{ID: "exoLibass", Label: "Exo libass", Value: "true"},
			{ID: "exoSecondarySubtitle", Label: "Exo副字幕", Value: "default"},
			{ID: "exoDolbyVision", Label: "杜比视界策略", Value: "0"},
			{ID: "exoPreferredTextLangs", Label: "首选字幕语言", Value: ""},
			{ID: "exoDiskPreloadMs", Label: "Exo磁盘预读毫秒", Value: "120000"},
			{ID: "mpvTlsVerify", Label: "MPV TLS校验", Value: "true"},
			{ID: "mpvDiskCache", Label: "MPV磁盘缓存", Value: "false"},
			{ID: "mpvGpuApi", Label: "MPV gpu-api", Value: "auto"},
			{ID: "videoEq", Label: "画面调色", Value: "off"},
			{ID: "audioEq", Label: "音频均衡", Value: "off"},
			{ID: "videoBrightness", Label: "画面亮度", Value: "0"},
			{ID: "videoContrast", Label: "画面对比度", Value: "0"},
			{ID: "videoSaturation", Label: "画面饱和度", Value: "0"},
			{ID: "videoGamma", Label: "画面伽马", Value: "0"},
			{ID: "videoHue", Label: "画面色相", Value: "0"},
			{ID: "videoTemperature", Label: "画面色温", Value: "0"},
			{ID: "videoSharpness", Label: "画面锐度", Value: "0"},
			{ID: "videoShadow", Label: "画面阴影", Value: "0"},
			{ID: "preloadNextEpisode", Label: "预解析下一集", Value: "false"},
			{ID: "subtitleFontScale", Label: "字幕字号", Value: "1.0"},
			{ID: "subtitlePos", Label: "字幕位置", Value: "0"},
			{ID: "subtitleColor", Label: "字幕颜色", Value: "#FFFFFF"},
			{ID: "subtitleBorderColor", Label: "字幕描边色", Value: "#000000"},
			{ID: "subtitleBorderSize", Label: "字幕描边", Value: "2"},
			{ID: "subtitleSecondaryPos", Label: "副字幕位置", Value: "10"},
			{ID: "subtitleBgColor", Label: "字幕背景", Value: "#00000000"},
			{ID: "audioEqBands", Label: "音频均衡频段", Value: ""},
			{ID: "audioDialogue", Label: "对白增强", Value: "0"},
			{ID: "audioBalance", Label: "声道平衡", Value: "0"},
			{ID: "danmakuOffsetMs", Label: "弹幕偏移毫秒", Value: "0"},
			{ID: "subtitleStyleMode", Label: "字幕样式模式", Value: "original"},
			{ID: "subtitleEdgeType", Label: "字幕描边类型", Value: "outline"},
			{ID: "subtitleTextOpacity", Label: "字幕正文透明度", Value: "100"},
			{ID: "subtitleBgOpacity", Label: "字幕背景透明度", Value: "100"},
			{ID: "subtitleEdgeOpacity", Label: "字幕描边透明度", Value: "100"},
			{ID: "subtitleOffsetMs", Label: "字幕时间偏移", Value: "0"},
			{ID: "subtitleShadowStrength", Label: "字幕阴影强度", Value: "50"},
			{ID: "subtitleFont", Label: "字幕字体", Value: "default"},
			{ID: "subtitleFontPath", Label: "字幕字体文件", Value: ""},
			{ID: "playerScaleLive", Label: "直播画面比例", Value: "default"},
			{ID: "playerBackground", Label: "后台播放", Value: "pip"},
			{ID: "playerSpeedLongPress", Label: "长按倍速", Value: "2.0"},
			{ID: "danmakuLoad", Label: "加载弹幕", Value: "true"},
			{ID: "danmakuAuto", Label: "自动搜索弹幕", Value: "true"},
			{ID: "danmakuSpiderFirst", Label: "片源弹幕优先", Value: "true"},
			{ID: "danmakuShowScroll", Label: "滚动弹幕", Value: "true"},
			{ID: "danmakuShowTop", Label: "顶部弹幕", Value: "true"},
			{ID: "danmakuShowBottom", Label: "底部弹幕", Value: "true"},
			{ID: "danmakuShowReverse", Label: "逆向弹幕", Value: "true"},
			{ID: "danmakuShowSpecial", Label: "特殊弹幕", Value: "true"},
			{ID: "danmakuShowPositioned", Label: "定位弹幕", Value: "true"},
			{ID: "danmakuFixedDurationMs", Label: "固定弹幕时长", Value: "5000"},
			{ID: "danmakuStrokeMode", Label: "弹幕描边", Value: "shadow"},
			{ID: "danmakuColorMode", Label: "弹幕颜色", Value: "original"},
			{ID: "danmakuFont", Label: "弹幕字体", Value: "default"},
			{ID: "danmakuRowsTop", Label: "顶部弹幕行数", Value: "3"},
			{ID: "danmakuRowsBottom", Label: "底部弹幕行数", Value: "3"},
			{ID: "danmakuMaxOnScreen", Label: "同屏弹幕上限", Value: "150"},
			{ID: "danmakuScrollArea", Label: "弹幕滚动区域", Value: "50"},
			{ID: "danmakuScrollGap", Label: "弹幕水平间距", Value: "8"},
			{ID: "danmakuShadowOpacity", Label: "弹幕阴影透明度", Value: "0.5"},
			{ID: "danmakuDurationMs", Label: "滚动弹幕时长", Value: "8000"},
			{ID: "danmakuLineSpacing", Label: "弹幕行距", Value: "1.4"},
			{ID: "danmakuBold", Label: "弹幕粗体", Value: "false"},
			{ID: "danmakuStrokeWidth", Label: "弹幕描边宽度", Value: "0.12"},
			{ID: "danmakuProjectionOffsetX", Label: "弹幕投影水平", Value: "0.08"},
			{ID: "danmakuProjectionOffsetY", Label: "弹幕投影垂直", Value: "0.08"},
			{ID: "danmakuProjectionOpacity", Label: "弹幕投影透明度", Value: "0.2"},
			{ID: "audioChannelMode", Label: "声道模式", Value: "auto"},
			{ID: "audioStability", Label: "音量稳定", Value: "0"},
			{ID: "audioBoost", Label: "音量提升", Value: "0"},
			{ID: "audioPreamp", Label: "前置衰减", Value: "0"},
			{ID: "audioLoudness", Label: "响度归一", Value: "false"},
			{ID: "audioCenterGain", Label: "中置增益", Value: "0"},
			{ID: "audioOffsetMs", Label: "音画偏移", Value: "0"},
			{ID: "playerSkipOpeningEnding", Label: "跳过片头片尾", Value: "true"},
			{ID: "bootLive", Label: "开机进直播", Value: "false"},
			{ID: "exoDiskPreloadThreads", Label: "Exo预读线程", Value: "1"},
			{ID: "exoDiskPreloadSizeMb", Label: "Exo预读容量MB", Value: "128"},
			{ID: "language", Label: "界面语言", Value: ""},
			{ID: "searchZhuyin", Label: "注音键盘", Value: "false"},
		},
		Cache: make(map[string]json.RawMessage),
	}
}

func defaultVodPlayerValue() string {
	if runtime.GOOS == "android" {
		return "innie#exo"
	}
	return "innie#mpv"
}

func defaultLivePlayerValue() string {
	if runtime.GOOS == "android" {
		return "innie#exo"
	}
	if runtime.GOOS == "windows" {
		return "innie#mpv"
	}
	return "innie#mpv"
}

// ResolvePlayerLive 直播播放器；空则平台默认。
func ResolvePlayerLive() string {
	v := strings.TrimSpace(Get(PlayerLive))
	if v != "" {
		return v
	}
	return defaultLivePlayerValue()
}

// ResolvePlayerVod 点播播放器。
func ResolvePlayerVod() string {
	v := strings.TrimSpace(Get(Player))
	if v != "" {
		return v
	}
	return defaultVodPlayerValue()
}

// Load 从数据库加载全局设置（owner=''），并补齐缺省项。
func Load() error {
	mu.Lock()
	defer mu.Unlock()
	if storeDB != nil {
		m, err := storeDB.ListSettings("")
		if err != nil {
			return err
		}
		for id, v := range m {
			found := false
			for i := range data.List {
				if data.List[i].ID == id {
					data.List[i].Value = v
					found = true
					break
				}
			}
			if !found {
				data.List = append(data.List, item{ID: id, Label: id, Value: v})
			}
		}
		if raw, ok := m["searchHistory"]; ok && raw != "" {
			if data.Cache == nil {
				data.Cache = map[string]json.RawMessage{}
			}
			data.Cache["searchHistory"] = json.RawMessage(raw)
		}
		if raw, ok := m["searchHot"]; ok && raw != "" {
			if data.Cache == nil {
				data.Cache = map[string]json.RawMessage{}
			}
			data.Cache["searchHot"] = json.RawMessage(raw)
		}
	}
	ensureSettingLocked(Home, "首页站", "")
	ensureSettingLocked(PlayerLive, "直播播放器", defaultLivePlayerValue())
	ensureSettingLocked(PlayerRender, "渲染方式", "surface")
	ensureSettingLocked(PlayerFailover, "自动切换播放器", "auto")
	ensureSettingLocked(RemoteAuth, "远端鉴权", "false")
	ensureSettingLocked(AllowRegister, "开放注册", "false")
	dropSettingLocked("backendProxyPlay")
	dropSettingLocked("crash")
	ensureSettingLocked(AudioPassThrough, "音频直通", "true")
	ensureSettingLocked(ExoDiskCache, "Exo磁盘缓存", "false")
	ensureSettingLocked(ExoAdblock, "Exo去广告", "true")
	ensureSettingLocked(ExoTunneling, "Exo隧道", "false")
	ensureSettingLocked(ExoPreferAac, "Exo优先AAC", "false")
	ensureSettingLocked(ExoSkipSilence, "Exo跳过静音", "false")
	ensureSettingLocked(ExoSoftAudioPrefer, "Exo软解音频优先", "false")
	ensureSettingLocked(ExoSoftVideoPrefer, "Exo软解视频优先", "false")
	ensureSettingLocked(ExoBuffer, "Exo缓冲倍率", "1")
	ensureSettingLocked(ExoLibass, "Exo libass", "true")
	ensureSettingLocked(ExoSecondarySubtitle, "Exo副字幕", "default")
	ensureSettingLocked(ExoDolbyVision, "Exo杜比视界", "0")
	ensureSettingLocked(ExoPreferredTextLangs, "Exo首选字幕语言", "")
	ensureSettingLocked(ExoDiskPreloadMs, "Exo磁盘预读毫秒", "120000")
	ensureSettingLocked(MpvTlsVerify, "MPV TLS校验", "true")
	ensureSettingLocked(MpvDiskCache, "MPV磁盘缓存", "false")
	ensureSettingLocked(MpvGpuApi, "MPV gpu-api", "auto")
	ensureSettingLocked(VideoEq, "画面调色", "off")
	ensureSettingLocked(AudioEq, "音频均衡", "off")
	ensureSettingLocked(VideoBrightness, "画面亮度", "0")
	ensureSettingLocked(VideoContrast, "画面对比度", "0")
	ensureSettingLocked(VideoSaturation, "画面饱和度", "0")
	ensureSettingLocked(VideoGamma, "画面伽马", "0")
	ensureSettingLocked(VideoHue, "画面色相", "0")
	ensureSettingLocked(VideoTemperature, "画面色温", "0")
	ensureSettingLocked(VideoSharpness, "画面锐度", "0")
	ensureSettingLocked(VideoShadow, "画面阴影", "0")
	ensureSettingLocked(PreloadNextEpisode, "预解析下一集", "false")
	ensureSettingLocked(SubtitleFontScale, "字幕字号", "1.0")
	ensureSettingLocked(SubtitlePos, "字幕位置", "0")
	ensureSettingLocked(SubtitleColor, "字幕颜色", "#FFFFFF")
	ensureSettingLocked(SubtitleBorderColor, "字幕描边色", "#000000")
	ensureSettingLocked(SubtitleBorderSize, "字幕描边", "2")
	ensureSettingLocked(SubtitleSecondaryPos, "副字幕位置", "10")
	ensureSettingLocked(SubtitleBgColor, "字幕背景", "#00000000")
	ensureSettingLocked(AudioEqBands, "音频均衡频段", "")
	ensureSettingLocked(AudioDialogue, "对白增强", "0")
	ensureSettingLocked(AudioBalance, "声道平衡", "0")
	ensureSettingLocked(DanmakuOffsetMs, "弹幕偏移毫秒", "0")
	ensureSettingLocked(SubtitleStyleMode, "字幕样式模式", "original")
	ensureSettingLocked(SubtitleEdgeType, "字幕描边类型", "outline")
	ensureSettingLocked(SubtitleTextOpacity, "字幕正文透明度", "100")
	ensureSettingLocked(SubtitleBgOpacity, "字幕背景透明度", "100")
	ensureSettingLocked(SubtitleEdgeOpacity, "字幕描边透明度", "100")
	ensureSettingLocked(SubtitleOffsetMs, "字幕时间偏移", "0")
	ensureSettingLocked(PlayerScaleLive, "直播画面比例", "default")
	ensureSettingLocked(PlayerBackground, "后台播放", "pip")
	ensureSettingLocked(PlayerSpeedLongPress, "长按倍速", "2.0")
	ensureSettingLocked(SubtitleShadowStrength, "字幕阴影强度", "50")
	ensureSettingLocked(SubtitleFont, "字幕字体", "default")
	ensureSettingLocked(SubtitleFontPath, "字幕字体文件", "")
	ensureSettingLocked(DanmakuLoad, "加载弹幕", "true")
	ensureSettingLocked(DanmakuAuto, "自动搜索弹幕", "true")
	ensureSettingLocked(DanmakuSpiderFirst, "片源弹幕优先", "true")
	ensureSettingLocked(DanmakuShowScroll, "滚动弹幕", "true")
	ensureSettingLocked(DanmakuShowTop, "顶部弹幕", "true")
	ensureSettingLocked(DanmakuShowBottom, "底部弹幕", "true")
	ensureSettingLocked(DanmakuShowReverse, "逆向弹幕", "true")
	ensureSettingLocked(DanmakuShowSpecial, "特殊弹幕", "true")
	ensureSettingLocked(DanmakuShowPositioned, "定位弹幕", "true")
	ensureSettingLocked(DanmakuFixedDurationMs, "固定弹幕时长", "5000")
	ensureSettingLocked(DanmakuStrokeMode, "弹幕描边", "shadow")
	ensureSettingLocked(DanmakuColorMode, "弹幕颜色", "original")
	ensureSettingLocked(DanmakuFont, "弹幕字体", "default")
	ensureSettingLocked(DanmakuRowsTop, "顶部弹幕行数", "3")
	ensureSettingLocked(DanmakuRowsBottom, "底部弹幕行数", "3")
	ensureSettingLocked(DanmakuMaxOnScreen, "同屏弹幕上限", "150")
	ensureSettingLocked(DanmakuScrollArea, "弹幕滚动区域", "50")
	ensureSettingLocked(DanmakuScrollGap, "弹幕水平间距", "8")
	ensureSettingLocked(DanmakuShadowOpacity, "弹幕阴影透明度", "0.5")
	ensureSettingLocked(DanmakuDurationMs, "滚动弹幕时长", "8000")
	ensureSettingLocked(DanmakuLineSpacing, "弹幕行距", "1.4")
	ensureSettingLocked(DanmakuBold, "弹幕粗体", "false")
	ensureSettingLocked(DanmakuStrokeWidth, "弹幕描边宽度", "0.12")
	ensureSettingLocked(DanmakuProjectionOffsetX, "弹幕投影水平", "0.08")
	ensureSettingLocked(DanmakuProjectionOffsetY, "弹幕投影垂直", "0.08")
	ensureSettingLocked(DanmakuProjectionOpacity, "弹幕投影透明度", "0.2")
	ensureSettingLocked(AudioChannelMode, "声道模式", "auto")
	ensureSettingLocked(AudioStability, "音量稳定", "0")
	ensureSettingLocked(AudioBoost, "音量提升", "0")
	ensureSettingLocked(AudioPreamp, "前置衰减", "0")
	ensureSettingLocked(AudioLoudness, "响度归一", "false")
	ensureSettingLocked(AudioCenterGain, "中置增益", "0")
	ensureSettingLocked(AudioOffsetMs, "音画偏移", "0")
	ensureSettingLocked(PlayerSkipOpeningEnding, "跳过片头片尾", "true")
	ensureSettingLocked(BootLive, "开机进直播", "false")
	ensureSettingLocked(SearchZhuyin, "注音键盘", "false")
	ensureSettingLocked(ExoDiskPreloadThreads, "Exo预读线程", "1")
	ensureSettingLocked(ExoDiskPreloadSizeMb, "Exo预读容量MB", "128")
	// 缺省项写入库（全局 owner=''）
	if storeDB != nil {
		for _, it := range data.List {
			if _, ok, _ := storeDB.GetSetting("", it.ID); !ok {
				_ = storeDB.SetSetting("", it.ID, it.Value)
			}
		}
	}
	return nil
}

func ensureSettingLocked(t Type, label, def string) {
	for _, it := range data.List {
		if it.ID == string(t) {
			return
		}
	}
	data.List = append(data.List, item{ID: string(t), Label: label, Value: def})
}

func dropSettingLocked(id string) {
	out := data.List[:0]
	for _, it := range data.List {
		if it.ID == id {
			continue
		}
		out = append(out, it)
	}
	data.List = out
}

// Save 将内存中的全局设置刷入数据库（owner=''）。单键 Set 已即时落库。
func Save() error {
	mu.RLock()
	defer mu.RUnlock()
	if storeDB == nil {
		return nil
	}
	for _, it := range data.List {
		if it.ID == "backendProxyPlay" || it.ID == "crash" {
			continue
		}
		if err := storeDB.SetSetting("", it.ID, it.Value); err != nil {
			return err
		}
	}
	if data.Cache != nil {
		if raw, ok := data.Cache["searchHistory"]; ok {
			_ = storeDB.SetSetting("", "searchHistory", string(raw))
		}
		if raw, ok := data.Cache["searchHot"]; ok {
			_ = storeDB.SetSetting("", "searchHot", string(raw))
		}
	}
	return nil
}

// Get 获取设置值（按当前 DataOwner；宿主机键始终全局）。
func Get(t Type) string {
	owner := resolveOwner(t)
	id := string(t)
	if storeDB != nil {
		if v, ok, err := storeDB.GetSetting(owner, id); err == nil && ok {
			return v
		}
		// 远端用户缺键：用内置缺省，不读宿主已选 vod/live。
		if owner != "" && !isHostOnly(t) {
			return defaultValue(id)
		}
	}
	mu.RLock()
	defer mu.RUnlock()
	for _, it := range data.List {
		if it.ID == id {
			return it.Value
		}
	}
	return ""
}

func defaultValue(id string) string {
	mu.RLock()
	defer mu.RUnlock()
	for _, it := range data.List {
		if it.ID == id {
			return it.Value
		}
	}
	return ""
}

// DefaultPlayUA 未配置 ua 时的播放缺省 User-Agent。
const DefaultPlayUA = util.OkHttpUA

// PlayUA 播放 User-Agent：设置 ua 非空则用之，否则 DefaultPlayUA。
func PlayUA() string {
	if v := strings.TrimSpace(Get(UA)); v != "" {
		return v
	}
	return DefaultPlayUA
}

// Set 设置值并立即写入数据库对应 owner。
func Set(t Type, value string) {
	if t == "backendProxyPlay" || t == "crash" {
		return
	}
	owner := resolveOwner(t)
	id := string(t)
	mu.Lock()
	if owner == "" {
		found := false
		for i := range data.List {
			if data.List[i].ID == id {
				data.List[i].Value = value
				found = true
				break
			}
		}
		if !found {
			data.List = append(data.List, item{ID: id, Label: id, Value: value})
		}
	}
	mu.Unlock()
	persistDB(owner, id, value)
}

// IsAdFilterEnabled M3U8 广告过滤开关。
func IsAdFilterEnabled() bool {
	v := strings.ToLower(strings.TrimSpace(Get(AdFilter)))
	return v == "" || v == "true" || v == "1" || v == "on"
}

// IsDanmakuEnabled 弹幕开关。
func IsDanmakuEnabled() bool {
	v := strings.ToLower(strings.TrimSpace(Get(DanmakuOn)))
	return v == "" || v == "true" || v == "1" || v == "on"
}

// IsLiveAcross 跨分组换台（默认开）。
func IsLiveAcross() bool { return boolSetting(LiveAcross, true) }

// IsLiveChange 播放失败自动换线（默认开）。
func IsLiveChange() bool { return boolSetting(LiveChange, true) }

// IsLiveInvert 反转上下换台方向（默认关）。
func IsLiveInvert() bool { return boolSetting(LiveInvert, false) }

func boolSetting(t Type, def bool) bool {
	v := strings.ToLower(strings.TrimSpace(Get(t)))
	if v == "" {
		return def
	}
	return v == "true" || v == "1" || v == "on"
}

func SetBool(t Type, on bool) {
	if on {
		Set(t, "true")
	} else {
		Set(t, "false")
	}
}

// GetM3U8FilterConfigJSON 返回原始 JSON 配置。
func GetM3U8FilterConfigJSON() string {
	return Get(M3U8Cfg)
}

// SearchHistory 搜索历史。
type SearchHistory struct {
	Items []string `json:"items"`
}

func searchCacheOwner() string { return hostclient.DataOwner() }

func GetSearchHistory() []string {
	owner := searchCacheOwner()
	var raw json.RawMessage
	if storeDB != nil {
		if v, ok, err := storeDB.GetSetting(owner, "searchHistory"); err == nil && ok && v != "" {
			raw = json.RawMessage(v)
		}
	}
	if len(raw) == 0 {
		mu.RLock()
		if owner == "" {
			raw = data.Cache["searchHistory"]
		}
		mu.RUnlock()
	}
	if len(raw) == 0 {
		return nil
	}
	var h SearchHistory
	if json.Unmarshal(raw, &h) == nil {
		out := make([]string, len(h.Items))
		copy(out, h.Items)
		for i, j := 0, len(out)-1; i < j; i, j = i+1, j-1 {
			out[i], out[j] = out[j], out[i]
		}
		return out
	}
	return nil
}

// IsIncognito 无痕模式：不写观看历史。
func IsIncognito() bool { return boolSetting(Incognito, false) }

// IsDLNARenderer 是否作为局域网 DLNA 被投端。
func IsDLNARenderer() bool { return boolSetting(DLNARenderer, false) }

// Entry 设置项快照（备份/恢复）。
type Entry struct {
	ID    string `json:"id"`
	Label string `json:"label"`
	Value string `json:"value"`
}

// ListEntries 返回当前设置列表副本。
func ListEntries() []Entry {
	mu.RLock()
	defer mu.RUnlock()
	out := make([]Entry, len(data.List))
	for i, it := range data.List {
		out[i] = Entry{ID: it.ID, Label: it.Label, Value: it.Value}
	}
	return out
}

// ReplaceEntries 事务性替换设置列表（保留 cache）。
func ReplaceEntries(entries []Entry) {
	mu.Lock()
	defer mu.Unlock()
	data.List = make([]item, len(entries))
	for i, e := range entries {
		data.List[i] = item{ID: e.ID, Label: e.Label, Value: e.Value}
	}
}

// EnsureDeviceUUID 确保设备 UUID 存在。
func EnsureDeviceUUID() string {
	if v := strings.TrimSpace(Get(DeviceUUID)); v != "" {
		return v
	}
	b := make([]byte, 16)
	_, _ = rand.Read(b)
	uuid := fmt.Sprintf("%x-%x-%x-%x-%x", b[0:4], b[4:6], b[6:8], b[8:10], b[10:16])
	Set(DeviceUUID, uuid)
	_ = Save()
	return uuid
}

// EnsureSyncPairCode 确保配对码存在（6 位数字）。
func EnsureSyncPairCode() string {
	if v := strings.TrimSpace(Get(SyncPairCode)); len(v) == 6 {
		return v
	}
	return ResetSyncPairCode()
}

// ResetSyncPairCode 重新生成配对码。
func ResetSyncPairCode() string {
	n, _ := rand.Int(rand.Reader, big.NewInt(900000))
	code := fmt.Sprintf("%06d", n.Int64()+100000)
	Set(SyncPairCode, code)
	_ = Save()
	return code
}

func GetSearchHot() []string {
	owner := searchCacheOwner()
	var raw json.RawMessage
	if storeDB != nil {
		if v, ok, err := storeDB.GetSetting(owner, "searchHot"); err == nil && ok && v != "" {
			raw = json.RawMessage(v)
		}
	}
	if len(raw) == 0 && owner == "" {
		mu.RLock()
		raw = data.Cache["searchHot"]
		mu.RUnlock()
	}
	if len(raw) == 0 {
		return nil
	}
	var h SearchHistory
	if json.Unmarshal(raw, &h) != nil {
		return nil
	}
	out := make([]string, 0, len(h.Items))
	for _, it := range h.Items {
		it = strings.TrimSpace(it)
		if it != "" {
			out = append(out, it)
		}
	}
	return out
}

func SetSearchHot(items []string) {
	seen := map[string]struct{}{}
	out := make([]string, 0, len(items))
	for _, it := range items {
		it = strings.TrimSpace(it)
		if it == "" {
			continue
		}
		if _, ok := seen[it]; ok {
			continue
		}
		seen[it] = struct{}{}
		out = append(out, it)
		if len(out) >= 40 {
			break
		}
	}
	b, _ := json.Marshal(SearchHistory{Items: out})
	owner := searchCacheOwner()
	if owner == "" {
		mu.Lock()
		if data.Cache == nil {
			data.Cache = map[string]json.RawMessage{}
		}
		data.Cache["searchHot"] = b
		mu.Unlock()
	}
	persistDB(owner, "searchHot", string(b))
}

func AddSearchHistory(q string) {
	owner := searchCacheOwner()
	var h SearchHistory
	if storeDB != nil {
		if v, ok, err := storeDB.GetSetting(owner, "searchHistory"); err == nil && ok && v != "" {
			_ = json.Unmarshal([]byte(v), &h)
		}
	}
	if len(h.Items) == 0 && owner == "" {
		mu.RLock()
		if raw, ok := data.Cache["searchHistory"]; ok {
			_ = json.Unmarshal(raw, &h)
		}
		mu.RUnlock()
	}
	for i, v := range h.Items {
		if v == q {
			h.Items = append(h.Items[:i], h.Items[i+1:]...)
			break
		}
	}
	h.Items = append(h.Items, q)
	if len(h.Items) > 30 {
		h.Items = h.Items[len(h.Items)-30:]
	}
	b, _ := json.Marshal(h)
	if owner == "" {
		mu.Lock()
		if data.Cache == nil {
			data.Cache = map[string]json.RawMessage{}
		}
		data.Cache["searchHistory"] = b
		mu.Unlock()
	}
	persistDB(owner, "searchHistory", string(b))
}
