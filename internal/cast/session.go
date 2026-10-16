package cast

import (
	"fmt"
	"io"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"
)

// Session 当前投屏目标（投送成功后记住，供探测/断开）。
type Session struct {
	Protocol Protocol
	Name     string
	Detail   string
	Label    string
	Location string // DLNA 描述 URL
	CastIP   string
	CastPort int
	AppBase  string
}

func (s Session) Key() string {
	return fmt.Sprintf("%s|%s|%s", s.Protocol, strings.TrimSpace(s.Name), strings.TrimSpace(s.Detail))
}

func SessionFromDevice(d Device) Session {
	s := Session{
		Protocol: d.Protocol,
		Name:     d.Name,
		Detail:   d.Detail,
		Label:    d.Label(),
		CastIP:   d.castIP,
		CastPort: d.castPort,
		AppBase:  d.appBase,
	}
	if d.Protocol == ProtocolDLNA {
		s.Location = d.Detail
		if loc := strings.TrimSpace(d.dlna.Location); loc != "" {
			s.Location = loc
			if s.Detail == "" {
				s.Detail = loc
			}
		}
	}
	if d.Protocol == ProtocolApp && s.AppBase == "" {
		s.AppBase = d.Detail
	}
	return s
}

var (
	sessionMu sync.Mutex
	current   *Session
)

// SetSession 记录当前投屏目标。
func SetSession(s Session) {
	sessionMu.Lock()
	defer sessionMu.Unlock()
	cp := s
	current = &cp
}

// ClearSession 清空投屏会话。
func ClearSession() {
	sessionMu.Lock()
	defer sessionMu.Unlock()
	current = nil
}

// GetSession 返回当前会话副本。
func GetSession() (Session, bool) {
	sessionMu.Lock()
	defer sessionMu.Unlock()
	if current == nil {
		return Session{}, false
	}
	return *current, true
}

// StatusResult 探测结果。
type StatusResult struct {
	Active   bool
	Protocol Protocol
	Name     string
	Detail   string
	Label    string
	State    string
	Key      string
}

// ProbeSession 探测当前会话是否仍在投。
func ProbeSession() StatusResult {
	s, ok := GetSession()
	if !ok {
		return StatusResult{Active: false}
	}
	out := StatusResult{
		Protocol: s.Protocol,
		Name:     s.Name,
		Detail:   s.Detail,
		Label:    s.Label,
		Key:      s.Key(),
	}
	switch s.Protocol {
	case ProtocolDLNA:
		loc := strings.TrimSpace(s.Location)
		if loc == "" {
			loc = s.Detail
		}
		d, err := ConnectDLNA(loc)
		if err != nil {
			ClearSession()
			return StatusResult{Active: false}
		}
		active, state, err := ProbeDLNA(d)
		if err != nil || !active {
			ClearSession()
			return StatusResult{Active: false, State: state}
		}
		out.Active = true
		out.State = state
		return out
	case ProtocolChromecast:
		active, state, err := probeChromecastActive(s.CastIP, s.CastPort)
		if err != nil || !active {
			ClearSession()
			return StatusResult{Active: false, State: state}
		}
		out.Active = true
		out.State = state
		return out
	case ProtocolApp:
		base := strings.TrimRight(strings.TrimSpace(s.AppBase), "/")
		if base == "" {
			base = strings.TrimRight(strings.TrimSpace(s.Detail), "/")
		}
		if !probeAppBase(base) {
			ClearSession()
			return StatusResult{Active: false}
		}
		out.Active = true
		out.State = "online"
		return out
	default:
		ClearSession()
		return StatusResult{Active: false}
	}
}

// StopSession 断开当前投屏并清会话。无会话或已死也返回 ok。
func StopSession() error {
	s, ok := GetSession()
	if !ok {
		return nil
	}
	var err error
	switch s.Protocol {
	case ProtocolDLNA:
		loc := strings.TrimSpace(s.Location)
		if loc == "" {
			loc = s.Detail
		}
		d, e := ConnectDLNA(loc)
		if e != nil {
			ClearSession()
			return nil
		}
		err = StopDLNA(d)
	case ProtocolChromecast:
		err = stopChromecast(s.CastIP, s.CastPort)
	case ProtocolApp:
		base := strings.TrimRight(strings.TrimSpace(s.AppBase), "/")
		if base == "" {
			base = strings.TrimRight(strings.TrimSpace(s.Detail), "/")
		}
		err = stopAppPeer(base)
	}
	ClearSession()
	return err
}

func probeAppBase(base string) bool {
	base = strings.TrimRight(strings.TrimSpace(base), "/")
	if base == "" {
		return false
	}
	client := &http.Client{Timeout: 4 * time.Second}
	req, err := http.NewRequest(http.MethodGet, base+"/device", nil)
	if err != nil {
		return false
	}
	resp, err := client.Do(req)
	if err != nil {
		return false
	}
	defer resp.Body.Close()
	_, _ = io.Copy(io.Discard, io.LimitReader(resp.Body, 4096))
	return resp.StatusCode == http.StatusOK
}

func stopAppPeer(base string) error {
	base = strings.TrimRight(strings.TrimSpace(base), "/")
	if base == "" {
		return fmt.Errorf("设备地址为空")
	}
	form := url.Values{}
	form.Set("do", "control")
	form.Set("type", "stop")
	req, err := http.NewRequest(http.MethodPost, base+"/action", strings.NewReader(form.Encode()))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	client := &http.Client{Timeout: 8 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	_, _ = io.Copy(io.Discard, io.LimitReader(resp.Body, 4096))
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("对端停止失败: %s", resp.Status)
	}
	return nil
}
