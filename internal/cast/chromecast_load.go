package cast

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/buger/jsonparser"
	castlib "github.com/vishen/go-chromecast/cast"
	pb "github.com/vishen/go-chromecast/cast/proto"
)

// Default Media Receiver。Chrome 投网页/直链视频也常用这个 AppId。
const defaultMediaReceiverAppID = "CC1AD845"

const (
	castSender   = "sender-0"
	castReceiver = "receiver-0"
	nsConnection = "urn:x-cast:com.google.cast.tp.connection"
	nsReceiver   = "urn:x-cast:com.google.cast.receiver"
	nsMedia      = "urn:x-cast:com.google.cast.media"
)

// go-chromecast 把 LAUNCH 应答超时写死为 5s，且只认带同一 requestId 的回包。
// 不少电视（尤其 Android TV Cast）会先推 RECEIVER_STATUS（requestId=0），
// Chrome / pychromecast 靠状态轮询等到 App 就绪；这里保持同样的等待行为，超时放宽到 30s。
func loadURLOnChromecast(ip string, port int, mediaURL, contentType string) error {
	if ip == "" || port == 0 {
		return fmt.Errorf("设备无效")
	}
	conn := castlib.NewConnection()
	if err := conn.Start(ip, port); err != nil {
		return fmt.Errorf("连接失败: %w", err)
	}
	defer func() { _ = conn.Close() }()

	s := newCastSession(conn)
	defer s.close()
	go s.pump()

	ctx, cancel := context.WithTimeout(context.Background(), 45*time.Second)
	defer cancel()

	connect := castlib.ConnectHeader
	if err := s.sendFireAndForget(ctx, &connect, castSender, castReceiver, nsConnection); err != nil {
		return fmt.Errorf("CONNECT: %w", err)
	}

	app, err := s.ensureDefaultReceiver(ctx)
	if err != nil {
		return err
	}

	mediaConnect := castlib.ConnectHeader
	if err := s.sendFireAndForget(ctx, &mediaConnect, castSender, app.TransportId, nsConnection); err != nil {
		return fmt.Errorf("媒体通道 CONNECT: %w", err)
	}

	streamType := "BUFFERED"
	lowURL := strings.ToLower(mediaURL)
	lowCT := strings.ToLower(contentType)
	if strings.Contains(lowURL, ".m3u8") || strings.Contains(lowCT, "mpegurl") {
		streamType = "LIVE"
	}
	load := &castlib.LoadMediaCommand{
		PayloadHeader: castlib.LoadHeader,
		CurrentTime:   0,
		Autoplay:      true,
		Media: castlib.MediaItem{
			ContentId:   mediaURL,
			ContentType: contentType,
			StreamType:  streamType,
		},
	}
	if err := s.sendFireAndForget(ctx, load, castSender, app.TransportId, nsMedia); err != nil {
		return fmt.Errorf("LOAD: %w", err)
	}
	// 给设备一点时间接收 LOAD，避免立刻关 TLS。
	time.Sleep(500 * time.Millisecond)
	return nil
}

type castSession struct {
	conn castlib.Conn

	mu      sync.Mutex
	reqID   atomic.Int64
	waiters map[int]chan *pb.CastMessage
	last    *castlib.ReceiverStatusResponse
	events  chan struct{}
	done    chan struct{}
}

func newCastSession(conn castlib.Conn) *castSession {
	return &castSession{
		conn:    conn,
		waiters: map[int]chan *pb.CastMessage{},
		events:  make(chan struct{}, 16),
		done:    make(chan struct{}),
	}
}

func (s *castSession) close() {
	select {
	case <-s.done:
	default:
		close(s.done)
	}
}

func (s *castSession) notify() {
	select {
	case s.events <- struct{}{}:
	default:
	}
}

func (s *castSession) pump() {
	for {
		select {
		case <-s.done:
			return
		case msg, ok := <-s.conn.MsgChan():
			if !ok {
				return
			}
			s.handleMsg(msg)
		}
	}
}

func (s *castSession) handleMsg(msg *pb.CastMessage) {
	if msg == nil || msg.PayloadUtf8 == nil {
		return
	}
	payload := []byte(*msg.PayloadUtf8)
	typ, _ := jsonparser.GetString(payload, "type")
	if typ == "RECEIVER_STATUS" {
		var st castlib.ReceiverStatusResponse
		if err := json.Unmarshal(payload, &st); err == nil {
			s.mu.Lock()
			s.last = &st
			s.mu.Unlock()
			s.notify()
		}
	}
	reqID, err := jsonparser.GetInt(payload, "requestId")
	if err != nil || reqID == 0 {
		return
	}
	s.mu.Lock()
	ch := s.waiters[int(reqID)]
	s.mu.Unlock()
	if ch != nil {
		select {
		case ch <- msg:
		default:
		}
	}
}

func (s *castSession) nextID() int {
	return int(s.reqID.Add(1))
}

func (s *castSession) sendFireAndForget(ctx context.Context, payload castlib.Payload, src, dst, ns string) error {
	id := s.nextID()
	payload.SetRequestId(id)
	if err := s.conn.Send(id, payload, src, dst, ns); err != nil {
		return err
	}
	// CONNECT/LOAD 经常没有带 requestId 的应答
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-time.After(150 * time.Millisecond):
		return nil
	}
}

func (s *castSession) getStatus(ctx context.Context) (*castlib.ReceiverStatusResponse, error) {
	id := s.nextID()
	req := castlib.GetStatusHeader
	req.SetRequestId(id)
	ch := make(chan *pb.CastMessage, 1)
	s.mu.Lock()
	s.waiters[id] = ch
	s.mu.Unlock()
	defer func() {
		s.mu.Lock()
		delete(s.waiters, id)
		s.mu.Unlock()
	}()

	if err := s.conn.Send(id, &req, castSender, castReceiver, nsReceiver); err != nil {
		return nil, err
	}

	tctx, cancel := context.WithTimeout(ctx, 8*time.Second)
	defer cancel()
	for {
		select {
		case <-tctx.Done():
			if st := s.snapshot(); st != nil {
				return st, nil
			}
			return nil, tctx.Err()
		case msg := <-ch:
			var st castlib.ReceiverStatusResponse
			if err := json.Unmarshal([]byte(*msg.PayloadUtf8), &st); err != nil {
				return nil, err
			}
			s.mu.Lock()
			s.last = &st
			s.mu.Unlock()
			return &st, nil
		case <-s.events:
			if st := s.snapshot(); st != nil {
				// 可能是推送的 RECEIVER_STATUS
				if len(st.Status.Applications) > 0 || st.Status.Volume.Level > 0 || true {
					return st, nil
				}
			}
		}
	}
}

func (s *castSession) snapshot() *castlib.ReceiverStatusResponse {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.last
}

func (s *castSession) ensureDefaultReceiver(ctx context.Context) (*castlib.Application, error) {
	st, err := s.getStatus(ctx)
	if err != nil {
		log.Printf("cast: 首次 GET_STATUS: %v", err)
	}
	if app := defaultMediaApp(st); app != nil {
		return app, nil
	}

	// 已有其它 App 时先 STOP，避免 LAUNCH 卡住（Chrome 也会抢会话）。
	if app := anyApp(st); app != nil && !app.IsIdleScreen {
		stop := castlib.StopHeader
		_ = s.sendFireAndForget(ctx, &stop, castSender, castReceiver, nsReceiver)
		time.Sleep(400 * time.Millisecond)
	}

	launch := &castlib.LaunchRequest{
		PayloadHeader: castlib.LaunchHeader,
		AppId:         defaultMediaReceiverAppID,
	}
	id := s.nextID()
	launch.SetRequestId(id)
	if err := s.conn.Send(id, launch, castSender, castReceiver, nsReceiver); err != nil {
		return nil, fmt.Errorf("LAUNCH: %w", err)
	}

	deadline := time.Now().Add(30 * time.Second)
	if d, ok := ctx.Deadline(); ok && d.Before(deadline) {
		deadline = d
	}
	waitCtx, cancel := context.WithDeadline(ctx, deadline)
	defer cancel()
	ticker := time.NewTicker(700 * time.Millisecond)
	defer ticker.Stop()

	for {
		if app := defaultMediaApp(s.snapshot()); app != nil {
			return app, nil
		}
		select {
		case <-waitCtx.Done():
			return nil, fmt.Errorf("启动默认播放器超时（已等约 30s）。Chrome 能投说明设备正常，可再试一次或改用 DLNA")
		case <-s.events:
			continue
		case <-ticker.C:
			if _, err := s.getStatus(waitCtx); err != nil {
				log.Printf("cast: GET_STATUS: %v", err)
			}
		}
	}
}

func defaultMediaApp(st *castlib.ReceiverStatusResponse) *castlib.Application {
	if st == nil {
		return nil
	}
	for i := range st.Status.Applications {
		app := &st.Status.Applications[i]
		if app.AppId == defaultMediaReceiverAppID && strings.TrimSpace(app.TransportId) != "" {
			return app
		}
	}
	return nil
}

func anyApp(st *castlib.ReceiverStatusResponse) *castlib.Application {
	if st == nil {
		return nil
	}
	for i := range st.Status.Applications {
		app := &st.Status.Applications[i]
		if app.AppId != "" {
			return app
		}
	}
	return nil
}
