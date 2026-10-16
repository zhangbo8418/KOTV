package dlna

import (
	"context"
	"fmt"
	"net/url"
	"strings"
	"time"

	"github.com/huin/goupnp/dcps/av1"
)

// ConnectByLocation 按设备描述 URL 重建 AVTransport 客户端。
func ConnectByLocation(location string) (Device, error) {
	location = strings.TrimSpace(location)
	if location == "" {
		return Device{}, fmt.Errorf("location 为空")
	}
	u, err := url.Parse(location)
	if err != nil {
		return Device{}, err
	}
	ctx, cancel := context.WithTimeout(context.Background(), 6*time.Second)
	defer cancel()
	clients, err := av1.NewAVTransport1ClientsByURLCtx(ctx, u)
	if err != nil {
		return Device{}, err
	}
	if len(clients) == 0 {
		return Device{}, fmt.Errorf("无 AVTransport: %s", location)
	}
	c := clients[0]
	name := c.ServiceClient.RootDevice.Device.FriendlyName
	if name == "" {
		name = location
	}
	return Device{
		Name:     name,
		Location: location,
		client:   c,
	}, nil
}

// Stop 停止渲染器播放。
func Stop(d Device) error {
	if d.client == nil {
		return fmt.Errorf("设备无效")
	}
	return d.client.Stop(0)
}

// TransportActive 探测当前传输是否仍在播/暂停（非 STOPPED）。
func TransportActive(d Device) (bool, string, error) {
	if d.client == nil {
		return false, "", fmt.Errorf("设备无效")
	}
	state, status, _, err := d.client.GetTransportInfo(0)
	if err != nil {
		return false, "", err
	}
	st := strings.ToUpper(strings.TrimSpace(state))
	active := st == "PLAYING" || st == "TRANSITIONING" || st == "PAUSED_PLAYBACK" || st == "RECORDING"
	_ = status
	return active, st, nil
}
