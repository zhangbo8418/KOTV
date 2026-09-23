package source

import (
	"io"
	"net/http"
	"net/url"
	"os"
	"path"
	"strings"
	"time"

	"github.com/bobo/KOTV/internal/util"
)

// Prepare 展开 video:// / push:// / *.strm。
// forceParse：video:// → 宿主嗅探（parse=1）。
// directPlay：push:// / .strm → 直播内层地址（parse=0）。
func Prepare(playURL string) (out string, forceParse, directPlay bool) {
	u := strings.TrimSpace(playURL)
	if u == "" {
		return "", false, false
	}
	lower := strings.ToLower(u)
	switch {
	case strings.HasPrefix(lower, "video://"):
		return strings.TrimSpace(u[len("video://"):]), true, false
	case strings.HasPrefix(lower, "push://"):
		return strings.TrimSpace(u[len("push://"):]), false, true
	case strmPath(u):
		if fetched := fetchStrmURL(u); fetched != "" {
			u = fetched
		}
		return u, false, true
	default:
		return playURL, false, false
	}
}

func strmPath(u string) bool {
	p := u
	if i := strings.Index(u, "?"); i >= 0 {
		p = u[:i]
	}
	if ju, err := url.Parse(u); err == nil && ju.Path != "" {
		p = ju.Path
	}
	return strings.HasSuffix(strings.ToLower(path.Base(p)), ".strm")
}

func fetchStrmURL(u string) string {
	u = strings.TrimSpace(u)
	if u == "" {
		return ""
	}
	lower := strings.ToLower(u)
	if strings.HasPrefix(lower, "http://") || strings.HasPrefix(lower, "https://") {
		return fetchStrmHTTP(u)
	}
	filePath := u
	if strings.HasPrefix(lower, "file://") {
		filePath = u[len("file://"):]
	}
	b, err := os.ReadFile(filePath)
	if err != nil {
		return u
	}
	return firstLine(string(b))
}

func fetchStrmHTTP(rawURL string) string {
	client := &http.Client{
		Timeout: 20 * time.Second,
		CheckRedirect: func(req *http.Request, via []*http.Request) error {
			return http.ErrUseLastResponse
		},
	}
	req, err := http.NewRequest(http.MethodGet, util.EncodeURL(rawURL), nil)
	if err != nil {
		return rawURL
	}
	req.Header.Set("User-Agent", "okhttp/4.12.0")
	resp, err := client.Do(req)
	if err != nil {
		return rawURL
	}
	defer resp.Body.Close()
	disp := resp.Header.Get("Content-Disposition")
	text := strings.Contains(disp, ".strm") || strings.Contains(disp, ".txt")
	if !text {
		return rawURL
	}
	b, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		return rawURL
	}
	line := firstLine(string(b))
	if line == "" {
		return rawURL
	}
	return line
}

func firstLine(s string) string {
	s = strings.TrimSpace(s)
	if s == "" {
		return ""
	}
	if i := strings.IndexAny(s, "\r\n"); i >= 0 {
		return strings.TrimSpace(s[:i])
	}
	return s
}
