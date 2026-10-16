package danmaku

import (
	"encoding/xml"
	"fmt"
	"io"
	"net/http"
	"os"
	"regexp"
	"strconv"
	"strings"
	"sync"

	"github.com/bobo/KOTV/internal/settings"
	"github.com/bobo/KOTV/internal/util"
)

// Item 单条弹幕。
type Item struct {
	Time    float64 // 秒
	Mode    int
	Size    int
	Color   int
	Content string
}

const (
	itemsMax     = 20000   // 单次解析条数上限
	bodyBytesMax = 8 << 20 // 读入字节上限（解码后同样拒绝更大正文）
)

var (
	mu    sync.RWMutex
	items []Item
	live  []string // 遥控即时弹幕
)

// Clear 清空已加载弹幕。
func Clear() {
	mu.Lock()
	items = nil
	live = nil
	mu.Unlock()
}

func errBodyTooLarge() error {
	return fmt.Errorf("弹幕正文超过 %d 字节", bodyBytesMax)
}

func readLimited(r io.Reader) ([]byte, error) {
	b, err := io.ReadAll(io.LimitReader(r, bodyBytesMax+1))
	if err != nil {
		return nil, err
	}
	if len(b) > bodyBytesMax {
		return nil, errBodyTooLarge()
	}
	return b, nil
}

func loadBody(pathOrURL string) (string, error) {
	if local, ok := util.FileURLPath(pathOrURL); ok {
		return readFileLimited(local)
	}
	if pathOrURL == "" || !strings.Contains(pathOrURL, "://") {
		return readFileLimited(pathOrURL)
	}
	req, err := http.NewRequest(http.MethodGet, pathOrURL, nil)
	if err != nil {
		return "", err
	}
	req.Header.Set("User-Agent", util.OkHttpUA)
	resp, err := util.GetClient().Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	raw, err := readLimited(resp.Body)
	if err != nil {
		return "", err
	}
	if resp.StatusCode >= 400 {
		return "", fmt.Errorf("弹幕下载失败: http=%d", resp.StatusCode)
	}
	b := util.DecodeContentEncoding(resp.Header.Get("Content-Encoding"), raw)
	if len(b) > bodyBytesMax {
		return "", errBodyTooLarge()
	}
	return string(b), nil
}

func readFileLimited(path string) (string, error) {
	st, err := os.Stat(path)
	if err != nil {
		return "", err
	}
	if st.Size() > bodyBytesMax {
		return "", errBodyTooLarge()
	}
	f, err := os.Open(path)
	if err != nil {
		return "", err
	}
	defer f.Close()
	b, err := readLimited(f)
	if err != nil {
		return "", err
	}
	return string(b), nil
}

func store(parsed []Item) {
	mu.Lock()
	items = parsed
	mu.Unlock()
}

// LoadURL 从弹幕地址加载。
func LoadURL(u string) error {
	if u == "" || !settings.IsDanmakuEnabled() {
		return nil
	}
	body, err := loadBody(u)
	if err != nil {
		return err
	}
	store(Parse(body))
	return nil
}

// LoadFile 从本地弹幕文件加载。
func LoadFile(path string) error {
	if path == "" || !settings.IsDanmakuEnabled() {
		return nil
	}
	body, err := readFileLimited(path)
	if err != nil {
		return err
	}
	store(Parse(body))
	return nil
}

// SearchAndLoad 用模板 API 搜索弹幕。
func SearchAndLoad(name, episode string) error {
	api := settings.Get(settings.DanmakuAPI)
	if api == "" || !settings.IsDanmakuEnabled() {
		return nil
	}
	u := api
	u = strings.ReplaceAll(u, "{name}", name)
	u = strings.ReplaceAll(u, "{episode}", episode)
	return LoadURL(u)
}

// PushLive 遥控即时弹幕。
func PushLive(text string) {
	if text == "" {
		return
	}
	mu.Lock()
	live = append(live, text)
	if len(live) > 100 {
		live = live[len(live)-100:]
	}
	mu.Unlock()
}

// PopLive 取出即时弹幕。
func PopLive() []string {
	mu.Lock()
	defer mu.Unlock()
	out := append([]string{}, live...)
	live = nil
	return out
}

// At 返回某播放进度附近的弹幕。
func At(positionMs int64, windowMs int64) []Item {
	mu.RLock()
	defer mu.RUnlock()
	sec := float64(positionMs) / 1000
	win := float64(windowMs) / 1000
	var out []Item
	for _, it := range items {
		if it.Time >= sec && it.Time < sec+win {
			out = append(out, it)
		}
	}
	return out
}

// Count 已加载弹幕数。
func Count() int {
	mu.RLock()
	defer mu.RUnlock()
	return len(items)
}

// Parse 解析 B 站 XML 或 [t,mode,size,color]text 格式。
func Parse(body string) []Item {
	body = strings.TrimSpace(body)
	if strings.Contains(body, "<d ") || strings.Contains(body, "<i>") {
		return parseXML(body)
	}
	return parseText(body)
}

type danmakuD struct {
	P    string `xml:"p,attr"`
	Text string `xml:",chardata"`
}

func parseXML(body string) []Item {
	dec := xml.NewDecoder(strings.NewReader(body))
	var out []Item
	sawD := false
	for len(out) < itemsMax {
		tok, err := dec.Token()
		if err != nil {
			break
		}
		se, ok := tok.(xml.StartElement)
		if !ok || se.Name.Local != "d" {
			continue
		}
		var d danmakuD
		if err := dec.DecodeElement(&d, &se); err != nil {
			break
		}
		sawD = true
		if it, ok := itemFromMeta(d.P, d.Text); ok {
			out = append(out, it)
		}
	}
	if !sawD {
		return parseText(body)
	}
	return out
}

func itemFromMeta(meta, text string) (Item, bool) {
	it := Item{Content: strings.TrimSpace(text), Mode: 1, Size: 25}
	parts := strings.Split(meta, ",")
	if len(parts) > 0 {
		it.Time, _ = strconv.ParseFloat(parts[0], 64)
	}
	if len(parts) > 1 {
		it.Mode, _ = strconv.Atoi(parts[1])
	}
	if len(parts) > 2 {
		it.Size, _ = strconv.Atoi(parts[2])
	}
	if len(parts) > 3 {
		it.Color, _ = strconv.Atoi(parts[3])
	}
	if it.Content == "" {
		return Item{}, false
	}
	return it, true
}

var textLineRe = regexp.MustCompile(`^\[([^\]]+)\](.*)$`)

func parseText(body string) []Item {
	var out []Item
	for _, line := range strings.Split(body, "\n") {
		if len(out) >= itemsMax {
			break
		}
		line = strings.TrimSpace(line)
		m := textLineRe.FindStringSubmatch(line)
		if m == nil {
			continue
		}
		if it, ok := itemFromMeta(m[1], m[2]); ok {
			out = append(out, it)
		}
	}
	return out
}

// FormatLive 格式化即时弹幕展示。
func FormatLive(text string) string {
	return fmt.Sprintf("[弹幕] %s", text)
}
