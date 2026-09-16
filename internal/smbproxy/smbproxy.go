// Package smbproxy 把 smb:// 转成本地 HTTP Range 代理，供桌面 MPV/FVP 播放。
package smbproxy

import (
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/bobo/KOTV/internal/playproxy"
	"github.com/hirochachacha/go-smb2"
)

type session struct {
	raw       string
	expiresAt time.Time
}

var (
	mu       sync.Mutex
	sessions = map[string]*session{}
)

// Rewrite 若为 smb:// 则登记并返回本机 /proxy/smb/?id=…；否则原样返回。
func Rewrite(raw string) string {
	raw = strings.TrimSpace(raw)
	if !strings.HasPrefix(strings.ToLower(raw), "smb://") {
		return raw
	}
	id := newID()
	mu.Lock()
	sessions[id] = &session{raw: raw, expiresAt: time.Now().Add(6 * time.Hour)}
	mu.Unlock()
	return fmt.Sprintf("%s/proxy/smb/?id=%s", playproxy.LocalHTTPBase(), id)
}

func newID() string {
	return fmt.Sprintf("%d", time.Now().UnixNano())
}

// Handle GET/HEAD /proxy/smb/?id=…（支持 Range）。
func Handle(w http.ResponseWriter, r *http.Request) {
	id := strings.TrimSpace(r.URL.Query().Get("id"))
	if id == "" {
		http.Error(w, "missing id", http.StatusBadRequest)
		return
	}
	mu.Lock()
	s := sessions[id]
	if s != nil && time.Now().After(s.expiresAt) {
		delete(sessions, id)
		s = nil
	}
	mu.Unlock()
	if s == nil {
		http.Error(w, "expired", http.StatusNotFound)
		return
	}
	f, size, closer, err := openSmb(s.raw)
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadGateway)
		return
	}
	defer closer()

	w.Header().Set("Accept-Ranges", "bytes")
	w.Header().Set("Content-Type", "application/octet-stream")

	if r.Method == http.MethodHead {
		w.Header().Set("Content-Length", strconv.FormatInt(size, 10))
		w.WriteHeader(http.StatusOK)
		return
	}

	start, end := int64(0), size-1
	status := http.StatusOK
	if rng := r.Header.Get("Range"); strings.HasPrefix(rng, "bytes=") {
		spec := strings.TrimPrefix(rng, "bytes=")
		parts := strings.SplitN(spec, "-", 2)
		if len(parts) == 2 {
			if parts[0] != "" {
				if v, e := strconv.ParseInt(parts[0], 10, 64); e == nil {
					start = v
				}
			}
			if parts[1] != "" {
				if v, e := strconv.ParseInt(parts[1], 10, 64); e == nil {
					end = v
				}
			}
			if start < 0 {
				start = 0
			}
			if end >= size {
				end = size - 1
			}
			if start <= end {
				status = http.StatusPartialContent
				w.Header().Set("Content-Range", fmt.Sprintf("bytes %d-%d/%d", start, end, size))
			} else {
				start, end = 0, size-1
			}
		}
	}
	length := end - start + 1
	w.Header().Set("Content-Length", strconv.FormatInt(length, 10))
	w.WriteHeader(status)
	if start > 0 {
		if _, err := f.Seek(start, io.SeekStart); err != nil {
			return
		}
	}
	_, _ = io.CopyN(w, f, length)
}

type smbFile interface {
	io.Reader
	io.Seeker
	io.Closer
}

func openSmb(raw string) (smbFile, int64, func(), error) {
	u, err := url.Parse(raw)
	if err != nil {
		return nil, 0, nil, err
	}
	host := u.Hostname()
	if host == "" {
		return nil, 0, nil, fmt.Errorf("smb host empty")
	}
	port := u.Port()
	if port == "" {
		port = "445"
	}
	user := ""
	pass := ""
	domain := ""
	if u.User != nil {
		user = u.User.Username()
		pass, _ = u.User.Password()
		if i := strings.IndexByte(user, ';'); i >= 0 {
			domain = user[:i]
			user = user[i+1:]
		}
	}
	path := strings.TrimPrefix(u.Path, "/")
	share, rest, ok := strings.Cut(path, "/")
	if !ok || share == "" {
		return nil, 0, nil, fmt.Errorf("smb share/path required")
	}
	rest = strings.ReplaceAll(rest, "/", "\\")

	conn, err := net.DialTimeout("tcp", net.JoinHostPort(host, port), 15*time.Second)
	if err != nil {
		return nil, 0, nil, err
	}
	d := &smb2.Dialer{
		Initiator: &smb2.NTLMInitiator{
			User:     user,
			Password: pass,
			Domain:   domain,
		},
	}
	s, err := d.Dial(conn)
	if err != nil {
		_ = conn.Close()
		return nil, 0, nil, err
	}
	fs, err := s.Mount(share)
	if err != nil {
		_ = s.Logoff()
		_ = conn.Close()
		return nil, 0, nil, err
	}
	f, err := fs.Open(rest)
	if err != nil {
		_ = fs.Umount()
		_ = s.Logoff()
		_ = conn.Close()
		return nil, 0, nil, err
	}
	st, err := f.Stat()
	if err != nil {
		_ = f.Close()
		_ = fs.Umount()
		_ = s.Logoff()
		_ = conn.Close()
		return nil, 0, nil, err
	}
	closer := func() {
		_ = f.Close()
		_ = fs.Umount()
		_ = s.Logoff()
		_ = conn.Close()
	}
	return f, st.Size(), closer, nil
}
