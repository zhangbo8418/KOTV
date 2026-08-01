// Package thunder 磁力/种子两阶段播放：
//	详情：magnet/thunder/.torrent 展开为媒体剧集
//	起播：转成本地 HTTP 给播放器边下边播
// 桌面端用 anacrolix/torrent 边下边播。
package thunder

import (
	"bytes"
	"context"
	"crypto/md5"
	"encoding/base64"
	"encoding/hex"
	"fmt"
	"log"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"

	analog "github.com/anacrolix/log"
	"github.com/anacrolix/torrent"
	"github.com/bobo/KOTV/internal/model"
	"github.com/bobo/KOTV/internal/paths"
	"github.com/bobo/KOTV/internal/util"
)

const (
	metaTimeout   = 60 * time.Second // 等 DHT/tracker 元数据
	bufferTimeout = 45 * time.Second // 等片头可播字节
	minStartBytes = 512 << 10        // 512 KiB：够 demux 探头 + 起播
	startPieces   = 16               // 片头优先 piece 数
	readahead     = 32 << 20
	minMedia      = 30 << 20 // 最小媒体约 30MB
)

var (
	thunderPat = regexp.MustCompile(`(?i)^(magnet|thunder|ed2k):`)
	videoExt   = map[string]bool{
		"avi": true, "flv": true, "mkv": true, "mov": true, "mp4": true,
		"mpeg": true, "mpe": true, "mpg": true, "wmv": true, "m4v": true,
		"webm": true, "ts": true, "m2ts": true, "rmvb": true, "rm": true,
	}
	audioExt = map[string]bool{
		"aac": true, "ape": true, "flac": true, "mp3": true, "m4a": true, "ogg": true,
	}
	defaultTrackers = []string{
		"udp://tracker.opentrackr.org:1337/announce",
		"udp://open.stealth.si:80/announce",
		"udp://tracker.torrent.eu.org:451/announce",
		"udp://exodus.desync.com:6969/announce",
		"udp://open.demonii.com:1337/announce",
		"udp://explodie.org:6969/announce",
		"udp://tracker.moeking.me:6969/announce",
		"udp://tracker.tiny-vps.com:6969/announce",
		"udp://retracker.lanta-net.ru:2710/announce",
	}
)

func init() {
	analog.Default = analog.Default.WithFilterLevel(analog.Error)
}

type entry struct {
	t     *torrent.Torrent
	file  *torrent.File
	index int
}

var (
	mu      sync.Mutex
	client  *torrent.Client
	entries = map[string]*entry{} // ih#index → entry
	portFn  func() int

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
// 注意：会同步等待 DHT 元数据（最长 metaTimeout），勿在详情页关键路径调用。
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

// 返回可播媒体剧集。
func Parse(raw string) ([]model.Episode, error) {
	return ParseContext(context.Background(), raw)
}

// ParseContext 在 parent 取消或超时后停止等待元数据。
func ParseContext(parent context.Context, raw string) ([]model.Episode, error) {
	raw = Decode(strings.TrimSpace(raw))
	if androidThunderEnabled() {
		// Android 只用迅雷 Native，不再回落 anacrolix。
		return tryAndroidParse(raw)
	}
	if parent == nil {
		parent = context.Background()
	}
	ctx, cancel := context.WithTimeout(parent, metaTimeout)
	defer cancel()

	t, torrentFile, err := openTorrent(ctx, raw)
	if err != nil {
		return nil, err
	}
	files := mediaFiles(t)
	if len(files) == 0 {
		return nil, fmt.Errorf("未找到超过 30MB 的媒体文件")
	}
	out := make([]model.Episode, 0, len(files))
	for _, f := range files {
		idx := fileIndex(t, f)
		play := playURL(torrentFile, f.DisplayPath(), idx, t.InfoHash().HexString())
		name := filepath.Base(f.DisplayPath())
		desc := formatSize(f.Length())
		out = append(out, model.Episode{
			Name: desc + name,
			Desc: desc,
			URL:  play,
		})
	}
	log.Printf("thunder: parsed %d media file(s) from %s", len(out), shorten(raw))
	return out, nil
}

// Fetch 返回本地 HTTP 播放地址。
// 流程：解析元数据 → 选定媒体文件 → 优先拉片头 → 等到有足够字节（或明确失败）再交给播放器，
// 避免「无 peer / 无数据」时就返回 URL 导致假就绪、黑屏假播放中。
func Fetch(raw string) (string, error) {
	raw = Decode(strings.TrimSpace(raw))
	if androidThunderEnabled() {
		// Android：迅雷 SDK（magnet / thunder / ed2k / ftp 等），与 TV 一致，不走 anacrolix。
		return tryAndroidFetch(raw)
	}
	low := strings.ToLower(raw)
	if strings.HasPrefix(low, "ed2k:") || strings.HasPrefix(low, "ftp:") {
		return "", fmt.Errorf("电驴/FTP 仅 Android 迅雷支持")
	}
	setProgress("meta", 0, 0, 0, "正在获取磁力元数据…")
	metaCtx, metaCancel := context.WithTimeout(context.Background(), metaTimeout)
	defer metaCancel()

	path, name, index, ih, isFileMagnet := parsePlayURL(raw)
	var t *torrent.Torrent
	var file *torrent.File
	var err error

	if isFileMagnet {
		if path != "" {
			t, err = addTorrentFile(metaCtx, path)
		} else if ih != "" {
			t, err = torrentByInfoHash(ih)
		} else {
			setProgress("error", 0, 0, 0, "无效的磁力剧集地址")
			return "", fmt.Errorf("无效的磁力剧集地址")
		}
		if err != nil {
			setProgress("error", 0, 0, 0, err.Error())
			return "", err
		}
		file = fileByIndex(t, index)
		if file == nil {
			file = pickLargest(t.Files())
		}
		_ = name
	} else {
		t, _, err = openTorrent(metaCtx, raw)
		if err != nil {
			setProgress("error", 0, 0, 0, err.Error())
			return "", err
		}
		file = pickLargest(mediaFiles(t))
		if file == nil {
			file = pickLargest(t.Files())
		}
		index = fileIndex(t, file)
	}
	if file == nil {
		setProgress("error", 0, 0, 0, "未找到可播文件")
		return "", fmt.Errorf("未找到可播文件")
	}

	selectFile(t, file)
	ih = t.InfoHash().HexString()
	key := entryKey(ih, index)
	mu.Lock()
	entries[key] = &entry{t: t, file: file, index: index}
	mu.Unlock()

	log.Printf("thunder: meta ok ih=%s idx=%d file=%s size=%d，等待片头缓冲…",
		ih, index, filepath.Base(file.DisplayPath()), file.Length())
	setProgress("buffer", 0, 0, minStartBytes, "正在缓冲片头…")

	bufCtx, bufCancel := context.WithTimeout(context.Background(), bufferTimeout)
	defer bufCancel()
	if err := waitHeadBuffer(bufCtx, t, file); err != nil {
		setProgress("error", 0, file.BytesCompleted(), minStartBytes, err.Error())
		return "", err
	}

	st := t.Stats()
	u := localURL(key)
	setProgress("ready", st.ActivePeers+st.ConnectedSeeders, file.BytesCompleted(), minStartBytes, "片头就绪")
	log.Printf("thunder: fetch ready ih=%s idx=%d file=%s url=%s peers=%d seeders=%d buffered=%d",
		ih, index, filepath.Base(file.DisplayPath()), u, st.ActivePeers, st.ConnectedSeeders, file.BytesCompleted())
	return u, nil
}

// IsLocalStream 是否为本模块产出的本地流（卡顿时勿重建播放器）。
func IsLocalStream(u string) bool {
	return strings.Contains(u, "/proxy/bt/")
}

// waitHeadBuffer 等到片头有足够字节再开播；无节点/无数据时返回明确错误，避免假就绪。
func waitHeadBuffer(ctx context.Context, t *torrent.Torrent, file *torrent.File) error {
	need := int64(minStartBytes)
	if file.Length() > 0 && file.Length() < need {
		need = file.Length()
	}
	ticker := time.NewTicker(400 * time.Millisecond)
	defer ticker.Stop()
	var lastLog time.Time
	for {
		done := file.BytesCompleted()
		st := t.Stats()
		peers := st.ActivePeers + st.ConnectedSeeders
		pct := 0
		if need > 0 {
			pct = int(done * 100 / need)
			if pct > 100 {
				pct = 100
			}
		}
		setProgress("buffer", peers, done, need, fmt.Sprintf("片头缓冲 %d%% · 节点 %d", pct, peers))
		if done >= need {
			return nil
		}
		if time.Since(lastLog) >= 2*time.Second {
			lastLog = time.Now()
			log.Printf("thunder: buffering peers=%d pending=%d total=%d bytes=%d/%d",
				st.ActivePeers, st.PendingPeers, st.TotalPeers, done, need)
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
			log.Printf("thunder: buffer timeout with %d bytes, start anyway", done)
			return nil
		case <-ticker.C:
		}
	}
}

func openTorrent(ctx context.Context, raw string) (*torrent.Torrent, string, error) {
	c, err := ensureClient()
	if err != nil {
		return nil, "", err
	}
	dir := paths.Ensure(filepath.Join(paths.Root(), "thunder", md5str(raw)))
	torrentPath := filepath.Join(dir, "task.torrent")

	if isTorrentURL(raw) && (strings.HasPrefix(raw, "http://") || strings.HasPrefix(raw, "https://")) {
		path, err := downloadRemoteTorrent(ctx, raw, torrentPath)
		if err != nil {
			return nil, "", err
		}
		t, err := c.AddTorrentFromFile(path)
		if err != nil {
			return nil, "", fmt.Errorf("打开远程种子失败: %w", err)
		}
		t.AllowDataDownload()
		t.AllowDataUpload()
		if t.Info() == nil {
			select {
			case <-t.GotInfo():
			case <-ctx.Done():
				return nil, "", fmt.Errorf("等待种子元数据超时")
			}
		}
		return t, path, nil
	}
	if strings.HasPrefix(strings.ToLower(raw), "file://") || (!strings.Contains(raw, "://") && strings.HasSuffix(strings.ToLower(raw), ".torrent")) {
		path := strings.TrimPrefix(raw, "file://")
		t, err := c.AddTorrentFromFile(path)
		return t, path, err
	}

	t, err := c.AddMagnet(raw)
	if err != nil {
		return nil, "", fmt.Errorf("添加磁力失败: %w", err)
	}
	t.AddTrackers([][]string{defaultTrackers})
	t.AllowDataDownload()
	t.AllowDataUpload()

	if t.Info() == nil {
		select {
		case <-t.GotInfo():
		case <-ctx.Done():
			return nil, "", fmt.Errorf("等待磁力元数据超时")
		}
	}
	if err := writeMetainfo(t, torrentPath); err != nil {
		log.Printf("thunder: write torrent warn: %v", err)
		torrentPath = ""
	}
	return t, torrentPath, nil
}

func downloadRemoteTorrent(ctx context.Context, raw, dest string) (string, error) {
	if st, err := os.Stat(dest); err == nil && st.Size() > 0 {
		return dest, nil
	}
	body, err := util.HTTPGetBytes(raw, nil)
	if err != nil {
		return "", fmt.Errorf("下载远程种子失败: %w", err)
	}
	if len(body) < 16 {
		return "", fmt.Errorf("远程种子内容过短")
	}
	// 粗检：bencode 字典或以 "d" 开头；部分站点会返回 HTML 错误页。
	if body[0] != 'd' && !bytes.Contains(body[:min(64, len(body))], []byte("d8:announce")) {
		ct := http.DetectContentType(body)
		if strings.Contains(ct, "text/html") || strings.Contains(ct, "text/plain") {
			return "", fmt.Errorf("远程地址未返回有效 .torrent")
		}
	}
	if err := os.WriteFile(dest, body, 0o644); err != nil {
		return "", err
	}
	_ = ctx
	return dest, nil
}

func addTorrentFile(ctx context.Context, path string) (*torrent.Torrent, error) {
	c, err := ensureClient()
	if err != nil {
		return nil, err
	}
	t, err := c.AddTorrentFromFile(path)
	if err != nil {
 // 回落：若只有 magnet 登记过，用已有 client 里的 torrent
		return nil, fmt.Errorf("打开种子失败: %w", err)
	}
	t.AllowDataDownload()
	t.AllowDataUpload()
	if t.Info() == nil {
		select {
		case <-t.GotInfo():
		case <-ctx.Done():
			return nil, fmt.Errorf("等待种子元数据超时")
		}
	}
	return t, nil
}

func writeMetainfo(t *torrent.Torrent, path string) error {
	if t.Info() == nil {
		return fmt.Errorf("no info")
	}
	mi := t.Metainfo()
	f, err := os.Create(path)
	if err != nil {
		return err
	}
	defer f.Close()
	return mi.Write(f)
}

func playURL(torrentFile, name string, index int, ih string) string {
	q := url.Values{}
	q.Set("name", filepath.Base(name))
	q.Set("index", strconv.Itoa(index))
	if ih != "" {
		q.Set("ih", ih)
	}
	// 路径放 query，避免 magnet://C:\Users\... 被 url.Parse 拆坏（盘符冒号/反斜杠）。
	if torrentFile != "" {
		q.Set("path", torrentFile)
	}
	return "magnet://local?" + q.Encode()
}

func parsePlayURL(raw string) (path, name string, index int, ih string, ok bool) {
	lower := strings.ToLower(raw)
	if strings.HasPrefix(lower, "magnet:?") {
		return "", "", 0, "", false
	}
	if !strings.HasPrefix(lower, "magnet://") {
		return "", "", 0, "", false
	}
	u, err := url.Parse(raw)
	if err != nil {
		return "", "", 0, "", false
	}
	path = u.Query().Get("path")
	if path == "" {
		// 兼容旧格式 magnet://host/path?...
		path = u.Path
		if u.Host != "" && u.Host != "local" {
			path = u.Host + u.Path
		}
	}
	name = u.Query().Get("name")
	ih = u.Query().Get("ih")
	index, _ = strconv.Atoi(u.Query().Get("index"))
	if u.Host == "local" || path != "" || ih != "" {
		return path, name, index, ih, true
	}
	return "", "", 0, "", false
}

func torrentByInfoHash(ih string) (*torrent.Torrent, error) {
	c, err := ensureClient()
	if err != nil {
		return nil, err
	}
	for _, t := range c.Torrents() {
		if strings.EqualFold(t.InfoHash().HexString(), ih) {
			t.AllowDataDownload()
			return t, nil
		}
	}
	return nil, fmt.Errorf("未找到种子任务 ih=%s（请重新打开详情解析）", ih)
}

func mediaFiles(t *torrent.Torrent) []*torrent.File {
	var out []*torrent.File
	for _, f := range t.Files() {
		if f == nil {
			continue
		}
		ext := strings.TrimPrefix(strings.ToLower(filepath.Ext(f.DisplayPath())), ".")
		if isMedia(ext, f.Length()) {
			out = append(out, f)
		}
	}
	return out
}

func isMedia(ext string, size int64) bool {
	return (videoExt[ext] || audioExt[ext]) && size > minMedia
}

func pickLargest(files []*torrent.File) *torrent.File {
	var best *torrent.File
	var n int64
	for _, f := range files {
		if f != nil && f.Length() > n {
			best, n = f, f.Length()
		}
	}
	return best
}

func fileIndex(t *torrent.Torrent, file *torrent.File) int {
	if file == nil {
		return 0
	}
	for i, f := range t.Files() {
		if f == file {
			return i
		}
	}
	return 0
}

func fileByIndex(t *torrent.Torrent, index int) *torrent.File {
	files := t.Files()
	if index >= 0 && index < len(files) {
		return files[index]
	}
	return nil
}

func selectFile(t *torrent.Torrent, file *torrent.File) {
	for _, f := range t.Files() {
		if f == file {
			f.SetPriority(torrent.PiecePriorityNormal)
		} else {
			f.SetPriority(torrent.PiecePriorityNone)
		}
	}
	begin := file.BeginPieceIndex()
	end := file.EndPieceIndex()
	limit := begin + startPieces
	if limit > end {
		limit = end
	}
	for i := begin; i < limit; i++ {
		prio := torrent.PiecePriorityHigh
		if i < begin+4 {
			prio = torrent.PiecePriorityNow
		}
		t.Piece(i).SetPriority(prio)
	}
}

func ensureClient() (*torrent.Client, error) {
	mu.Lock()
	defer mu.Unlock()
	if client != nil {
		return client, nil
	}
	cfg := torrent.NewDefaultClientConfig()
	cfg.DataDir = paths.Ensure(filepath.Join(paths.Root(), "thunder"))
	cfg.ListenPort = 0
	cfg.NoDefaultPortForwarding = true
	cfg.Seed = true
	cfg.DisableIPv6 = true
	cfg.EstablishedConnsPerTorrent = 100
	cfg.HalfOpenConnsPerTorrent = 50
	cfg.HeaderObfuscationPolicy.Preferred = false
	cfg.HeaderObfuscationPolicy.RequirePreferred = false
	cfg.Logger = analog.Default.WithFilterLevel(analog.Error)
	c, err := torrent.NewClient(cfg)
	if err != nil {
		return nil, err
	}
	client = c
	log.Printf("thunder: client ready (engine=anacrolix)")
	return client, nil
}

// ClearStorage 关闭 BT 客户端并删除 thunder 下载目录，返回大约释放字节数。
func ClearStorage() (int64, error) {
	tryAndroidClear()
	mu.Lock()
	c := client
	client = nil
	entries = map[string]*entry{}
	mu.Unlock()
	if c != nil {
		c.Close()
	}
	dir := filepath.Join(paths.Root(), "thunder")
	var total int64
	_ = filepath.Walk(dir, func(_ string, info os.FileInfo, err error) error {
		if err == nil && info != nil && !info.IsDir() {
			total += info.Size()
		}
		return nil
	})
	if err := os.RemoveAll(dir); err != nil && !os.IsNotExist(err) {
		return total, err
	}
	_ = os.MkdirAll(dir, 0o755)
	setProgress("idle", 0, 0, 0, "磁力缓存已清理")
	log.Printf("thunder: storage cleared (~%d bytes)", total)
	return total, nil
}

func entryKey(ih string, index int) string {
	return fmt.Sprintf("%s#%d", ih, index)
}

func localURL(key string) string {
	port := 9978
	if portFn != nil {
		if p := portFn(); p > 0 {
			port = p
		}
	}
	return fmt.Sprintf("http://127.0.0.1:%d/proxy/bt/%s", port, url.PathEscape(key))
}

func md5str(s string) string {
	sum := md5.Sum([]byte(s))
	return hex.EncodeToString(sum[:])
}

func formatSize(n int64) string {
	if n <= 0 {
		return ""
	}
	units := []string{"bytes", "KB", "MB", "GB", "TB"}
	v := float64(n)
	i := 0
	for v >= 1024 && i < len(units)-1 {
		v /= 1024
		i++
	}
	return fmt.Sprintf("[%.1f %s] ", v, units[i])
}

func shorten(s string) string {
	if len(s) > 80 {
		return s[:80] + "…"
	}
	return s
}

func lookup(key string) (*entry, bool) {
	mu.Lock()
	defer mu.Unlock()
	// path escape 可能把 # 编成 %23
	if e, ok := entries[key]; ok {
		return e, true
	}
	if u, err := url.PathUnescape(key); err == nil {
		if e, ok := entries[u]; ok {
			return e, true
		}
	}
	return nil, false
}

// Handle getLocalUrl：本地 HTTP + Range 边下边播。
func Handle(w http.ResponseWriter, r *http.Request) {
	key := strings.TrimPrefix(r.URL.Path, "/proxy/bt/")
	key = strings.Trim(key, "/")
	if key == "" {
		http.Error(w, "missing key", http.StatusBadRequest)
		return
	}
	e, ok := lookup(key)
	if !ok || e == nil || e.file == nil {
		http.Error(w, "torrent not ready", http.StatusNotFound)
		return
	}
	off := parseRangeStart(r.Header.Get("Range"))
	prioritizeAround(e.t, e.file, off)

	reader := e.file.NewReader()
	defer reader.Close()
	reader.SetReadahead(readahead)
	reader.SetResponsive()
	reader.SetContext(r.Context())

	name := filepath.Base(e.file.DisplayPath())
	w.Header().Set("Content-Type", contentType(name))
	w.Header().Set("Accept-Ranges", "bytes")
	http.ServeContent(w, r, name, time.Time{}, reader)
}

func parseRangeStart(h string) int64 {
	h = strings.TrimSpace(h)
	if !strings.HasPrefix(h, "bytes=") {
		return 0
	}
	spec := strings.TrimPrefix(h, "bytes=")
	if i := strings.IndexByte(spec, '-'); i >= 0 {
		spec = spec[:i]
	}
	n, _ := strconv.ParseInt(spec, 10, 64)
	if n < 0 {
		return 0
	}
	return n
}

func prioritizeAround(t *torrent.Torrent, file *torrent.File, fileOff int64) {
	info := t.Info()
	if info == nil || info.PieceLength <= 0 || file == nil {
		return
	}
	if fileOff < 0 {
		fileOff = 0
	}
	if file.Length() > 0 && fileOff >= file.Length() {
		fileOff = file.Length() - 1
	}
	abs := file.Offset() + fileOff
	idx := int(abs / int64(info.PieceLength))
	begin, end := file.BeginPieceIndex(), file.EndPieceIndex()
	if idx < begin {
		idx = begin
	}
	if idx >= end {
		idx = end - 1
	}
	for i := idx; i < end && i < idx+12; i++ {
		prio := torrent.PiecePriorityHigh
		if i == idx {
			prio = torrent.PiecePriorityNow
		}
		t.Piece(i).SetPriority(prio)
	}
}

func contentType(name string) string {
	switch strings.ToLower(filepath.Ext(name)) {
	case ".mp4", ".m4v":
		return "video/mp4"
	case ".mkv":
		return "video/x-matroska"
	case ".webm":
		return "video/webm"
	default:
		return "application/octet-stream"
	}
}
