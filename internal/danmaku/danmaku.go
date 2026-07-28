package danmaku

import (
	"encoding/xml"
	"fmt"
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

// LoadURL 从弹幕地址加载。
func LoadURL(u string) error {
	if u == "" || !settings.IsDanmakuEnabled() {
		return nil
	}
	body, err := util.HTTPGet(u, nil)
	if err != nil {
		return err
	}
	parsed := Parse(body)
	mu.Lock()
	items = parsed
	mu.Unlock()
	return nil
}

// LoadFile 从本地弹幕文件加载。
func LoadFile(path string) error {
	if path == "" || !settings.IsDanmakuEnabled() {
		return nil
	}
	b, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	parsed := Parse(string(b))
	mu.Lock()
	items = parsed
	mu.Unlock()
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

type bilibiliXML struct {
	D []struct {
		P    string `xml:"p,attr"`
		Text string `xml:",chardata"`
	} `xml:"d"`
}

func parseXML(body string) []Item {
	var doc bilibiliXML
	if err := xml.Unmarshal([]byte(body), &doc); err != nil {
		return parseText(body)
	}
	var out []Item
	for _, d := range doc.D {
		parts := strings.Split(d.P, ",")
		it := Item{Content: strings.TrimSpace(d.Text), Mode: 1, Size: 25}
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
		if it.Content != "" {
			out = append(out, it)
		}
	}
	return out
}

var textLineRe = regexp.MustCompile(`^\[([^\]]+)\](.*)$`)

func parseText(body string) []Item {
	var out []Item
	for _, line := range strings.Split(body, "\n") {
		line = strings.TrimSpace(line)
		m := textLineRe.FindStringSubmatch(line)
		if m == nil {
			continue
		}
		meta := strings.Split(m[1], ",")
		it := Item{Content: strings.TrimSpace(m[2]), Mode: 1, Size: 25}
		if len(meta) > 0 {
			it.Time, _ = strconv.ParseFloat(meta[0], 64)
		}
		if len(meta) > 1 {
			it.Mode, _ = strconv.Atoi(meta[1])
		}
		if len(meta) > 2 {
			it.Size, _ = strconv.Atoi(meta[2])
		}
		if len(meta) > 3 {
			it.Color, _ = strconv.Atoi(meta[3])
		}
		if it.Content != "" {
			out = append(out, it)
		}
	}
	return out
}

// FormatLive 格式化即时弹幕展示。
func FormatLive(text string) string {
	return fmt.Sprintf("[弹幕] %s", text)
}
