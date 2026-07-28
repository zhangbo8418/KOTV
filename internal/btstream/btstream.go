// Package btstream 将 magnet 转为本地 HTTP 流，供 VLC/mpv 边下边播。
package btstream

import (
	"context"
	"fmt"
	"log"
	"net/http"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"github.com/anacrolix/torrent"
	"github.com/bobo/KOTV/internal/paths"
)

const (
	metaTimeout   = 90 * time.Second
	bufferTimeout = 60 * time.Second
	minStartBytes = 512 << 10 // 512 KiB，够 VLC 探头 + 起播
	readahead     = 8 << 20   // 8 MiB
	startPieces   = 16        // 优先拉片头若干 piece
)

var videoExt = map[string]bool{
	".mp4": true, ".mkv": true, ".avi": true, ".ts": true, ".m2ts": true,
	".mov": true, ".flv": true, ".wmv": true, ".webm": true, ".mpg": true,
	".mpeg": true, ".m4v": true, ".rmvb": true, ".rm": true, ".3gp": true,
}

// 只用较稳的 UDP tracker；去掉常 500 的 http://tracker.openbittorrent.com。
var defaultTrackers = []string{
	"udp://tracker.opentrackr.org:1337/announce",
	"udp://open.stealth.si:80/announce",
	"udp://tracker.torrent.eu.org:451/announce",
	"udp://exodus.desync.com:6969/announce",
	"udp://tracker.moeking.me:6969/announce",
	"udp://tracker.tiny-vps.com:6969/announce",
	"udp://retracker.lanta-net.ru:2710/announce",
	"udp://open.demonii.com:1337/announce",
}

type entry struct {
	t    *torrent.Torrent
	file *torrent.File
}

var (
	mu      sync.Mutex
	client  *torrent.Client
	entries = map[string]*entry{} // infohash hex → entry
	portFn  func() int
)

// SetPortFunc 注入本地 HTTP 服务端口。
func SetPortFunc(fn func() int) { portFn = fn }

// IsMagnet 判断是否为 magnet 链接。
func IsMagnet(u string) bool {
	return strings.HasPrefix(strings.ToLower(strings.TrimSpace(u)), "magnet:")
}

func ensureClient() (*torrent.Client, error) {
	mu.Lock()
	defer mu.Unlock()
	if client != nil {
		return client, nil
	}
	cfg := torrent.NewDefaultClientConfig()
	cfg.DataDir = paths.Ensure(filepath.Join(paths.Root(), "bt"))
	cfg.ListenPort = 0
	cfg.NoDefaultPortForwarding = true
	cfg.Seed = true
	cfg.DisableIPv6 = true
	cfg.EstablishedConnsPerTorrent = 80
	cfg.HalfOpenConnsPerTorrent = 40
	c, err := torrent.NewClient(cfg)
	if err != nil {
		return nil, fmt.Errorf("启动 BT 客户端失败: %w", err)
	}
	client = c
	log.Printf("btstream: client ready dataDir=%s", cfg.DataDir)
	return client, nil
}

// Resolve 解析 magnet，等片头有数据后再返回本地可播 HTTP 地址。
func Resolve(ctx context.Context, magnet string) (string, error) {
	magnet = strings.TrimSpace(magnet)
	if !IsMagnet(magnet) {
		return "", fmt.Errorf("不是磁力链接")
	}
	if ctx == nil {
		ctx = context.Background()
	}
	metaCtx, cancel := context.WithTimeout(ctx, metaTimeout)
	defer cancel()

	c, err := ensureClient()
	if err != nil {
		return "", err
	}

	t, err := c.AddMagnet(magnet)
	if err != nil {
		return "", fmt.Errorf("添加磁力失败: %w", err)
	}
	ih := t.InfoHash().HexString()
	mu.Lock()
	if e, ok := entries[ih]; ok && e != nil && e.file != nil {
		done := e.file.BytesCompleted()
		mu.Unlock()
		if done >= minStartBytes {
			return localURL(ih), nil
		}
		// 已登记但数据不够：继续等缓冲。
		if err := waitBuffer(metaCtx, t, e.file); err != nil {
			return "", err
		}
		return localURL(ih), nil
	}
	mu.Unlock()

	t.AddTrackers([][]string{defaultTrackers})

	select {
	case <-t.GotInfo():
	case <-metaCtx.Done():
		t.Drop()
		return "", fmt.Errorf("等待磁力元数据超时（可检查网络或换带 tracker 的链接）")
	}

	file := pickVideo(t.Files())
	if file == nil {
		t.Drop()
		return "", fmt.Errorf("磁力中未找到视频文件")
	}
	// 只拉选中视频；片头 piece 提优先级，方便边下边播。
	for _, f := range t.Files() {
		if f == file {
			f.Download()
		} else {
			f.SetPriority(torrent.PiecePriorityNone)
		}
	}
	prioritizeStart(t, file)

	mu.Lock()
	entries[ih] = &entry{t: t, file: file}
	mu.Unlock()

	name := filepath.Base(file.DisplayPath())
	log.Printf("btstream: meta ok ih=%s file=%s size=%d，等待节点与片头缓冲…", ih, name, file.Length())

	bufCtx, bufCancel := context.WithTimeout(ctx, bufferTimeout)
	defer bufCancel()
	if err := waitBuffer(bufCtx, t, file); err != nil {
		return "", err
	}

	st := t.Stats()
	log.Printf("btstream: ready ih=%s peers=%d seeders=%d buffered=%d/%d",
		ih, st.ActivePeers, st.ConnectedSeeders, file.BytesCompleted(), file.Length())
	return localURL(ih), nil
}

func prioritizeStart(t *torrent.Torrent, file *torrent.File) {
	begin := file.BeginPieceIndex()
	end := file.EndPieceIndex()
	limit := begin + startPieces
	if limit > end {
		limit = end
	}
	for i := begin; i < limit; i++ {
		t.Piece(i).SetPriority(torrent.PiecePriorityNow)
	}
}

func waitBuffer(ctx context.Context, t *torrent.Torrent, file *torrent.File) error {
	ticker := time.NewTicker(500 * time.Millisecond)
	defer ticker.Stop()
	var lastLog time.Time
	for {
		done := file.BytesCompleted()
		st := t.Stats()
		peers := st.ActivePeers + st.ConnectedSeeders
		if done >= minStartBytes {
			return nil
		}
		if time.Since(lastLog) >= 2*time.Second {
			lastLog = time.Now()
			log.Printf("btstream: buffering peers=%d pending=%d total=%d bytes=%d/%d",
				st.ActivePeers, st.PendingPeers, st.TotalPeers, done, minStartBytes)
		}
		select {
		case <-ctx.Done():
			if peers == 0 && done == 0 {
				return fmt.Errorf("暂无可用节点，无法开始播放（资源可能无人做种）")
			}
			if done == 0 {
				return fmt.Errorf("片头缓冲超时（已连 %d 节点，仍无数据）", peers)
			}
			// 有一点数据也先开播，避免死等。
			log.Printf("btstream: buffer timeout with %d bytes, start anyway", done)
			return nil
		case <-ticker.C:
		}
	}
}

func localURL(ih string) string {
	port := 9978
	if portFn != nil {
		if p := portFn(); p > 0 {
			port = p
		}
	}
	return fmt.Sprintf("http://127.0.0.1:%d/proxy/bt/%s", port, ih)
}

func pickVideo(files []*torrent.File) *torrent.File {
	var best *torrent.File
	var bestLen int64
	var anyBest *torrent.File
	var anyLen int64
	for _, f := range files {
		if f == nil || f.Length() <= 0 {
			continue
		}
		if f.Length() > anyLen {
			anyBest, anyLen = f, f.Length()
		}
		ext := strings.ToLower(filepath.Ext(f.DisplayPath()))
		if videoExt[ext] && f.Length() > bestLen {
			best, bestLen = f, f.Length()
		}
	}
	if best != nil {
		return best
	}
	return anyBest
}

func lookup(ih string) (*entry, bool) {
	mu.Lock()
	defer mu.Unlock()
	e, ok := entries[ih]
	return e, ok
}

func contentType(name string) string {
	switch strings.ToLower(filepath.Ext(name)) {
	case ".mp4", ".m4v":
		return "video/mp4"
	case ".mkv":
		return "video/x-matroska"
	case ".webm":
		return "video/webm"
	case ".avi":
		return "video/x-msvideo"
	case ".ts", ".m2ts":
		return "video/mp2t"
	default:
		return "application/octet-stream"
	}
}

// Handle 提供 /proxy/bt/{infohash} 边下边播（支持 Range）。
func Handle(w http.ResponseWriter, r *http.Request) {
	ih := strings.TrimPrefix(r.URL.Path, "/proxy/bt/")
	ih = strings.Trim(ih, "/")
	if i := strings.IndexByte(ih, '/'); i >= 0 {
		ih = ih[:i]
	}
	if ih == "" {
		http.Error(w, "missing infohash", http.StatusBadRequest)
		return
	}
	e, ok := lookup(ih)
	if !ok || e == nil || e.file == nil {
		http.Error(w, "torrent not ready", http.StatusNotFound)
		return
	}

	reader := e.file.NewReader()
	defer reader.Close()
	reader.SetReadahead(readahead)
	reader.SetResponsive()

	name := filepath.Base(e.file.DisplayPath())
	w.Header().Set("Content-Type", contentType(name))
	w.Header().Set("Accept-Ranges", "bytes")
	w.Header().Set("Content-Disposition", fmt.Sprintf("inline; filename=%q", name))
	log.Printf("btstream: serve %s %s range=%q peers=%d", r.Method, name, r.Header.Get("Range"), e.t.Stats().ActivePeers)
	http.ServeContent(w, r, name, time.Time{}, reader)
}
