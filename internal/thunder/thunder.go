// Package thunder 磁力/种子两阶段播放：
//	详情：magnet/thunder/.torrent 展开为媒体剧集
//	起播：转成本地 HTTP 给播放器边下边播
//
// 桌面端（!android）用 anacrolix/torrent；Android 走 Native 迅雷（见 android.go）。
package thunder

import (
	"context"
	"encoding/base64"
	"log"
	"regexp"
	"strings"
	"sync"

	"github.com/bobo/KOTV/internal/model"
)

var (
	thunderPat = regexp.MustCompile(`(?i)^(magnet|thunder|ed2k):`)

	portFn func() int

	progressMu sync.Mutex
	progress   = FetchProgress{Phase: "idle"}
)

// FetchProgress 当前磁力任务进度（供 UI 轮询）。
type FetchProgress struct {
	Phase   string `json:"phase"` // idle|meta|buffer|ready|error
	Peers   int    `json:"peers"`
	Bytes   int64  `json:"bytes"`
	Need    int64  `json:"need"`
	Message string `json:"message"`
}

// CurrentProgress 返回最近一次 Fetch/展开进度快照。
func CurrentProgress() FetchProgress {
	if p, ok := tryAndroidProgress(); ok {
		return p
	}
	progressMu.Lock()
	defer progressMu.Unlock()
	return progress
}

// SetExpandProgress 详情展开阶段文案。
func SetExpandProgress(msg string) {
	setProgress("expand", 0, 0, 0, msg)
}

func setProgress(phase string, peers int, bytes, need int64, msg string) {
	progressMu.Lock()
	defer progressMu.Unlock()
	progress = FetchProgress{
		Phase:   phase,
		Peers:   peers,
		Bytes:   bytes,
		Need:    need,
		Message: msg,
	}
}

// SetPortFunc 注入本地 HTTP 端口（配合本地代理）。
func SetPortFunc(fn func() int) { portFn = fn }

// Match 判断是否为磁力/迅雷链或种子。
func Match(raw string) bool {
	raw = strings.TrimSpace(raw)
	if raw == "" {
		return false
	}
	if thunderPat.MatchString(raw) {
		return true
	}
	return isTorrentURL(raw)
}

func isTorrentURL(raw string) bool {
	u := strings.ToLower(strings.Split(raw, ";")[0])
	if strings.HasPrefix(u, "magnet") {
		return false
	}
	return strings.HasSuffix(u, ".torrent")
}

// Decode 解码 thunder://。
func Decode(raw string) string {
	raw = strings.TrimSpace(raw)
	lower := strings.ToLower(raw)
	if !strings.HasPrefix(lower, "thunder://") {
		return raw
	}
	enc := raw[len("thunder://"):]
	b, err := base64.StdEncoding.DecodeString(enc)
	if err != nil {
		b, err = base64.URLEncoding.DecodeString(enc)
		if err != nil {
			return raw
		}
	}
	s := string(b)
	if len(s) > 4 && strings.HasPrefix(s, "AA") && strings.HasSuffix(s, "ZZ") {
		return s[2 : len(s)-2]
	}
	return s
}

// ParseVod：把磁力/迅雷剧集展开为媒体文件列表。
// 注意：会同步等待元数据，勿在详情页关键路径调用。
func ParseVod(vod *model.Vod) {
	ParseVodContext(context.Background(), vod)
}

// ParseVodContext 可取消的磁力展开；ctx 取消后立即停止后续 magnet 解析。
func ParseVodContext(ctx context.Context, vod *model.Vod) {
	if vod == nil {
		return
	}
	setProgress("expand", 0, 0, 0, "正在展开磁力文件列表…")
	for i := range vod.VodFlags {
		if ctx.Err() != nil {
			log.Printf("thunder: parse cancelled")
			return
		}
		parseFlag(ctx, &vod.VodFlags[i])
	}
	if ctx.Err() != nil {
		return
	}
	vod.SetCurrentFlag(0)
	setProgress("ready", 0, 0, 0, "磁力文件列表已更新")
}

// NeedsParse 详情里是否含需展开的 magnet/thunder/.torrent。
func NeedsParse(vod *model.Vod) bool {
	if vod == nil {
		return false
	}
	for _, f := range vod.VodFlags {
		for _, ep := range f.Episodes {
			if Match(ep.URL) {
				return true
			}
		}
	}
	return false
}

// CloneFlags 深拷贝线路/剧集，供后台展开时不与 UI 共享底层数组。
func CloneFlags(src []model.Flag) []model.Flag {
	if len(src) == 0 {
		return nil
	}
	out := make([]model.Flag, len(src))
	for i, f := range src {
		out[i] = f
		if len(f.Episodes) > 0 {
			eps := make([]model.Episode, len(f.Episodes))
			copy(eps, f.Episodes)
			out[i].Episodes = eps
		}
	}
	return out
}

func parseFlag(ctx context.Context, f *model.Flag) {
	var kept []model.Episode
	var expanded []model.Episode
	for _, ep := range f.Episodes {
		if ctx.Err() != nil {
			// 未处理完的原链保留，避免取消后剧集列表变空
			kept = append(kept, ep)
			continue
		}
		if !Match(ep.URL) {
			kept = append(kept, ep)
			continue
		}
		eps, err := ParseContext(ctx, ep.URL)
		if err != nil || len(eps) == 0 {
			if ctx.Err() == nil {
				log.Printf("thunder: parse fail url=%q err=%v", shorten(ep.URL), err)
			}
			kept = append(kept, ep) // 保留原链，起播时再试
			continue
		}
		expanded = append(expanded, eps...)
	}
	if len(expanded) == 0 {
		return
	}
	f.Episodes = append(kept, expanded...)
}

// Parse 返回可播媒体剧集。
func Parse(raw string) ([]model.Episode, error) {
	return ParseContext(context.Background(), raw)
}

// IsLocalStream 是否为本模块产出的本地流（卡顿时勿重建播放器）。
func IsLocalStream(u string) bool {
	return strings.Contains(u, "/proxy/bt/")
}

// Stop 打断进行中的磁力 Fetch/解析等待（对齐 TV Source.stop → Thunder.stop）。
// 不清理已落盘缓存；仅取消当前等待并停掉 Android 迅雷任务。
func Stop() {
	stopPlatform()
	setProgress("idle", 0, 0, 0, "已取消")
}

func shorten(s string) string {
	if len(s) > 80 {
		return s[:80] + "…"
	}
	return s
}
