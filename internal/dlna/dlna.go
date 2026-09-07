package dlna

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"net"
	"net/url"
	"runtime"
	"strings"
	"sync"
	"time"

	"github.com/bobo/KOTV/internal/util"
	"github.com/huin/goupnp/dcps/av1"
	"github.com/huin/goupnp/httpu"
	"github.com/huin/goupnp/ssdp"
)

// Device 可投屏的 MediaRenderer。
type Device struct {
	Name     string
	Location string
	client   *av1.AVTransport1
}

// CastOptions 投出可选参数。
type CastOptions struct {
	Title      string
	Headers    map[string]string
	PositionMs int64 // 起播续看位置
}

var (
	mu      sync.Mutex
	devices []Device
)

// Discover 搜索局域网 MediaRenderer。
func Discover(timeout time.Duration) ([]Device, error) {
	if timeout <= 0 {
		timeout = 3 * time.Second
	}
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()

	// Android 11+：Go net.Interfaces 会 netlinkrib；有注入 IP 时直接绑地址发 SSDP。
	if runtime.GOOS == "android" {
		if ip := util.LanIP(); ip != "" {
			return discoverWithHostIP(ctx, ip)
		}
	}

	clients, errs, err := av1.NewAVTransport1ClientsCtx(ctx)
	if err != nil {
		if ip := util.LanIP(); ip != "" {
			log.Printf("DLNA: default discover failed (%v); retry via %s", err, ip)
			return discoverWithHostIP(ctx, ip)
		}
		return nil, err
	}
	for _, e := range errs {
		if e != nil {
			log.Printf("DLNA discover warning: %v", e)
		}
	}

	out := make([]Device, 0, len(clients))
	for _, c := range clients {
		name := c.ServiceClient.RootDevice.Device.FriendlyName
		if name == "" {
			name = c.ServiceClient.Location.String()
		}
		out = append(out, Device{
			Name:     name,
			Location: c.ServiceClient.Location.String(),
			client:   c,
		})
	}
	mu.Lock()
	devices = out
	mu.Unlock()
	return out, nil
}

// discoverWithHostIP 在指定 IPv4 上发 SSDP（不调用 net.Interfaces）。
func discoverWithHostIP(ctx context.Context, hostIP string) ([]Device, error) {
	hc, err := httpu.NewHTTPUClientAddr(hostIP)
	if err != nil {
		return nil, fmt.Errorf("HTTPU %s: %w", hostIP, err)
	}
	defer hc.Close()

	searchCtx, cancel := context.WithTimeout(ctx, 2*time.Second)
	defer cancel()
	responses, err := ssdp.RawSearch(searchCtx, hc, av1.URN_AVTransport_1, 3)
	if err != nil {
		return nil, err
	}

	out := make([]Device, 0, len(responses))
	seen := map[string]bool{}
	for _, response := range responses {
		loc, err := response.Location()
		if err != nil || loc == nil {
			continue
		}
		key := loc.String()
		if seen[key] {
			continue
		}
		seen[key] = true
		clients, err := av1.NewAVTransport1ClientsByURLCtx(ctx, loc)
		if err != nil || len(clients) == 0 {
			if err != nil {
				log.Printf("DLNA probe %s: %v", key, err)
			}
			continue
		}
		c := clients[0]
		name := c.ServiceClient.RootDevice.Device.FriendlyName
		if name == "" {
			name = key
		}
		out = append(out, Device{
			Name:     name,
			Location: key,
			client:   c,
		})
	}
	mu.Lock()
	devices = out
	mu.Unlock()
	return out, nil
}

// Devices 返回最近一次发现的设备。
func Devices() []Device {
	mu.Lock()
	defer mu.Unlock()
	out := make([]Device, len(devices))
	copy(out, devices)
	return out
}

// Cast 向设备推送媒体 URL（无额外选项）。
func Cast(d Device, mediaURL, title string) error {
	return CastWith(d, mediaURL, CastOptions{Title: title})
}

// CastWith 投送并可选写入自定义头、起播进度。
func CastWith(d Device, mediaURL string, opt CastOptions) error {
	if d.client == nil {
		return fmt.Errorf("设备无效")
	}
	mediaURL = RewriteLocalURL(mediaURL)
	if mediaURL == "" {
		return fmt.Errorf("媒体地址为空")
	}
	title := opt.Title
	if title == "" {
		title = "KO影视"
	}
	meta := buildDIDL(mediaURL, title, opt.Headers)
	if err := d.client.SetAVTransportURI(0, mediaURL, meta); err != nil {
		return fmt.Errorf("SetAVTransportURI: %w", err)
	}
	if err := d.client.Play(0, "1"); err != nil {
		return fmt.Errorf("Play: %w", err)
	}
	if opt.PositionMs > 1500 {
		_ = Seek(d, opt.PositionMs)
	}
	return nil
}

// Play 继续播放。
func Play(d Device) error {
	if d.client == nil {
		return fmt.Errorf("设备无效")
	}
	return d.client.Play(0, "1")
}

// Pause 暂停。
func Pause(d Device) error {
	if d.client == nil {
		return fmt.Errorf("设备无效")
	}
	return d.client.Pause(0)
}

// Stop 停止设备播放。
func Stop(d Device) error {
	if d.client == nil {
		return fmt.Errorf("设备无效")
	}
	return d.client.Stop(0)
}

// Seek 跳转到指定毫秒（REL_TIME）。
func Seek(d Device, ms int64) error {
	if d.client == nil {
		return fmt.Errorf("设备无效")
	}
	if ms < 0 {
		ms = 0
	}
	return d.client.Seek(0, "REL_TIME", FormatRelTime(ms))
}

// Next 下一资源（依赖接收端是否支持）。
func Next(d Device) error {
	if d.client == nil {
		return fmt.Errorf("设备无效")
	}
	return d.client.Next(0)
}

// Previous 上一资源。
func Previous(d Device) error {
	if d.client == nil {
		return fmt.Errorf("设备无效")
	}
	return d.client.Previous(0)
}

// PositionMs 查询当前进度毫秒；失败返回 -1。
func PositionMs(d Device) int64 {
	if d.client == nil {
		return -1
	}
	_, _, _, _, rel, _, _, _, err := d.client.GetPositionInfo(0)
	if err != nil {
		return -1
	}
	return parseRelTimeMs(rel)
}

// FormatRelTime 毫秒 → HH:MM:SS。
func FormatRelTime(ms int64) string {
	if ms < 0 {
		ms = 0
	}
	sec := ms / 1000
	h := sec / 3600
	m := (sec % 3600) / 60
	s := sec % 60
	return fmt.Sprintf("%d:%02d:%02d", h, m, s)
}

func parseRelTimeMs(rel string) int64 {
	rel = strings.TrimSpace(rel)
	parts := strings.Split(rel, ":")
	if len(parts) != 3 {
		return -1
	}
	var h, m, s int64
	if _, err := fmt.Sscanf(rel, "%d:%d:%d", &h, &m, &s); err != nil {
		return -1
	}
	return (h*3600 + m*60 + s) * 1000
}

// RewriteLocalURL 将 127.0.0.1 / localhost 改写为局域网 IP。
func RewriteLocalURL(raw string) string {
	u, err := url.Parse(raw)
	if err != nil {
		return raw
	}
	host := u.Hostname()
	if host == "127.0.0.1" || host == "localhost" || host == "::1" {
		ip := LocalIP()
		if ip == "" {
			return raw
		}
		port := u.Port()
		if port != "" {
			u.Host = ip + ":" + port
		} else {
			u.Host = ip
		}
		return u.String()
	}
	return raw
}

// LocalIP 获取首选局域网 IPv4。
func LocalIP() string {
	ifaces, err := net.Interfaces()
	if err != nil {
		return ""
	}
	for _, iface := range ifaces {
		if iface.Flags&net.FlagUp == 0 || iface.Flags&net.FlagLoopback != 0 {
			continue
		}
		addrs, _ := iface.Addrs()
		for _, addr := range addrs {
			var ip net.IP
			switch v := addr.(type) {
			case *net.IPNet:
				ip = v.IP
			case *net.IPAddr:
				ip = v.IP
			}
			if ip == nil || ip.IsLoopback() {
				continue
			}
			ip = ip.To4()
			if ip != nil {
				return ip.String()
			}
		}
	}
	return ""
}

func buildDIDL(mediaURL, title string, headers map[string]string) string {
	mime := "video/mp4"
	low := strings.ToLower(mediaURL)
	switch {
	case strings.Contains(low, ".m3u8"):
		mime = "application/vnd.apple.mpegurl"
	case strings.Contains(low, ".mkv"):
		mime = "video/x-matroska"
	case strings.Contains(low, ".webm"):
		mime = "video/webm"
	}
	esc := func(s string) string {
		s = strings.ReplaceAll(s, "&", "&amp;")
		s = strings.ReplaceAll(s, "<", "&lt;")
		s = strings.ReplaceAll(s, ">", "&gt;")
		s = strings.ReplaceAll(s, `"`, "&quot;")
		return s
	}
	desc := ""
	if len(headers) > 0 {
		if b, err := json.Marshal(headers); err == nil {
			desc = `<dc:description>` + esc(string(b)) + `</dc:description>`
		}
	}
	return fmt.Sprintf(
		`<DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/">`+
			`<item id="0" parentID="-1" restricted="1"><dc:title>%s</dc:title>%s<upnp:class>object.item.videoItem</upnp:class>`+
			`<res protocolInfo="http-get:*:%s:*">%s</res></item></DIDL-Lite>`,
		esc(title), desc, mime, esc(mediaURL),
	)
}
