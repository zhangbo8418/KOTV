package cast

import (
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"

	"github.com/bobo/KOTV/internal/settings"
	"github.com/bobo/KOTV/internal/util"
)

const ProtocolApp Protocol = "App"

type peerInfo struct {
	Name string `json:"name"`
	IP   string `json:"ip"`
	UUID string `json:"uuid"`
}

// discoverAppPeers 扫描本机网段 :9978/device，发现其它 KOTV / 兼容端。
func discoverAppPeers(timeout time.Duration) ([]Device, error) {
	if timeout <= 0 {
		timeout = 4 * time.Second
	}
	bases := peerScanBases()
	if len(bases) == 0 {
		return nil, nil
	}
	selfUUID := strings.TrimSpace(settings.EnsureDeviceUUID())
	selfIP := strings.TrimSpace(util.LanIP())

	client := &http.Client{Timeout: 900 * time.Millisecond}
	var (
		mu  sync.Mutex
		out []Device
		wg  sync.WaitGroup
	)
	sem := make(chan struct{}, 64)
	for _, base := range bases {
		base := base
		wg.Add(1)
		go func() {
			defer wg.Done()
			sem <- struct{}{}
			defer func() { <-sem }()
			d, ok := probeAppPeer(client, base, selfUUID, selfIP)
			if !ok {
				return
			}
			mu.Lock()
			out = append(out, d)
			mu.Unlock()
		}()
	}
	done := make(chan struct{})
	go func() {
		wg.Wait()
		close(done)
	}()
	select {
	case <-done:
	case <-time.After(timeout):
	}
	return out, nil
}

func peerScanBases() []string {
	lan := strings.TrimSpace(util.LanIP())
	if lan == "" {
		return nil
	}
	ip := net.ParseIP(lan)
	if ip == nil {
		return nil
	}
	ip4 := ip.To4()
	if ip4 == nil {
		return nil
	}
	prefix := fmt.Sprintf("%d.%d.%d.", ip4[0], ip4[1], ip4[2])
	out := make([]string, 0, 254)
	for i := 1; i <= 254; i++ {
		host := fmt.Sprintf("%s%d", prefix, i)
		if host == lan {
			continue
		}
		out = append(out, fmt.Sprintf("http://%s:9978", host))
	}
	return out
}

func probeAppPeer(client *http.Client, base, selfUUID, selfIP string) (Device, bool) {
	base = strings.TrimRight(strings.TrimSpace(base), "/")
	if base == "" {
		return Device{}, false
	}
	req, err := http.NewRequest(http.MethodGet, base+"/device", nil)
	if err != nil {
		return Device{}, false
	}
	resp, err := client.Do(req)
	if err != nil {
		return Device{}, false
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return Device{}, false
	}
	body, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil || len(body) == 0 {
		return Device{}, false
	}
	var info peerInfo
	if err := json.Unmarshal(body, &info); err != nil {
		return Device{}, false
	}
	name := strings.TrimSpace(info.Name)
	if name == "" {
		name = "局域网设备"
	}
	uuid := strings.TrimSpace(info.UUID)
	if selfUUID != "" && uuid != "" && uuid == selfUUID {
		return Device{}, false
	}
	reported := strings.TrimSpace(info.IP)
	host := ""
	if reported != "" {
		if strings.Contains(reported, "://") {
			if u, err := url.Parse(reported); err == nil {
				host = u.Hostname()
				if u.Scheme != "" && u.Host != "" {
					base = strings.TrimRight(reported, "/")
				}
			}
		} else {
			host = reported
			if h, _, err := net.SplitHostPort(reported); err == nil {
				host = h
			}
		}
	}
	if host == "" {
		if u, err := url.Parse(base); err == nil {
			host = u.Hostname()
		}
	}
	if selfIP != "" && host != "" && host == selfIP {
		return Device{}, false
	}
	return Device{
		Name:     name,
		Protocol: ProtocolApp,
		Detail:   base,
		appBase:  base,
		appUUID:  uuid,
	}, true
}

type appCastPayload struct {
	Config  string
	Device  string
	History string
}

func castAppPeer(d Device, payload appCastPayload) error {
	base := strings.TrimRight(strings.TrimSpace(d.appBase), "/")
	if base == "" {
		return fmt.Errorf("设备地址为空")
	}
	form := url.Values{}
	form.Set("do", "cast")
	if payload.Device != "" {
		form.Set("device", payload.Device)
	}
	if payload.Config != "" {
		form.Set("config", payload.Config)
	}
	if payload.History != "" {
		form.Set("history", payload.History)
	}
	req, err := http.NewRequest(http.MethodPost, base+"/action", strings.NewReader(form.Encode()))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	client := &http.Client{Timeout: 12 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
	if resp.StatusCode != http.StatusOK || strings.TrimSpace(string(raw)) != "OK" {
		msg := strings.TrimSpace(string(raw))
		if msg == "" {
			msg = resp.Status
		}
		return fmt.Errorf("对端拒绝投屏: %s", msg)
	}
	return nil
}
