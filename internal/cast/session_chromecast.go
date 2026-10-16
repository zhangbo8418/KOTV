package cast

import (
	"context"
	"fmt"
	"strings"
	"time"

	castlib "github.com/vishen/go-chromecast/cast"
)

func probeChromecastActive(ip string, port int) (bool, string, error) {
	ip = strings.TrimSpace(ip)
	if ip == "" || port <= 0 {
		return false, "", fmt.Errorf("Chromecast 地址无效")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 6*time.Second)
	defer cancel()
	conn := castlib.NewConnection()
	if err := conn.Start(ip, port); err != nil {
		return false, "", err
	}
	defer conn.Close()
	s := newCastSession(conn)
	go s.pump()
	defer s.close()
	connect := castlib.ConnectHeader
	_ = s.sendFireAndForget(ctx, &connect, castSender, castReceiver, nsConnection)
	st, err := s.getStatus(ctx)
	if err != nil {
		return false, "", err
	}
	if app := defaultMediaApp(st); app != nil {
		return true, "media", nil
	}
	if app := anyApp(st); app != nil && !app.IsIdleScreen {
		return true, "app", nil
	}
	return false, "idle", nil
}

func stopChromecast(ip string, port int) error {
	ip = strings.TrimSpace(ip)
	if ip == "" || port <= 0 {
		return fmt.Errorf("Chromecast 地址无效")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
	defer cancel()
	conn := castlib.NewConnection()
	if err := conn.Start(ip, port); err != nil {
		return err
	}
	defer conn.Close()
	s := newCastSession(conn)
	go s.pump()
	defer s.close()
	connect := castlib.ConnectHeader
	if err := s.sendFireAndForget(ctx, &connect, castSender, castReceiver, nsConnection); err != nil {
		return err
	}
	stop := castlib.StopHeader
	return s.sendFireAndForget(ctx, &stop, castSender, castReceiver, nsReceiver)
}
