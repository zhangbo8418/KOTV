//go:build !android

package source

import (
	"context"
	"encoding/json"
	"fmt"
	"net/url"
	"os/exec"
	"strings"
	"time"
)

func fetchPlatform(playURL string, _ json.RawMessage) (string, error) {
	playURL = strings.TrimSpace(playURL)
	if playURL == "" {
		return "", fmt.Errorf("空播放地址")
	}
	u, err := url.Parse(playURL)
	if err != nil {
		return "", err
	}
	scheme := strings.ToLower(u.Scheme)
	host := strings.ToLower(u.Hostname())

	switch {
	case strings.Contains(host, "youtube.com") || strings.Contains(host, "youtu.be"):
		return fetchYouTubeDesktop(playURL)
	case scheme == "jianpian" || scheme == "tvbox-xg" || scheme == "xg" || scheme == "xgplay":
		return "", fmt.Errorf("荐片 P2P 仅安卓支持（需 libjpa）: %s", playURL)
	case scheme == "tvbus":
		return "", fmt.Errorf("TVBus 仅安卓支持: %s", playURL)
	case isForceScheme(scheme):
		return "", fmt.Errorf("ForceTech (%s) 仅安卓支持: %s", scheme, playURL)
	default:
		return "", fmt.Errorf("桌面不支持该源协议: %s", playURL)
	}
}

func stopPlatform() {}

func isForceScheme(scheme string) bool {
	switch scheme {
	case "p2p", "p3p", "p4p", "p5p", "p6p", "p7p", "p8p", "p9p", "mitv":
		return true
	default:
		return false
	}
}

// fetchYouTubeDesktop 用 PATH 里的 yt-dlp / youtube-dl 解析可播直链。
// 优先选「音视频同封装」格式，避免 -g 打出两行分轨 URL。
func fetchYouTubeDesktop(playURL string) (string, error) {
	bin, err := lookYoutubeDL()
	if err != nil {
		return "", err
	}
	ctx, cancel := context.WithTimeout(context.Background(), 45*time.Second)
	defer cancel()

	out, err := exec.CommandContext(ctx, bin,
		"-g",
		"-f", "b/best[vcodec!=none][acodec!=none]/best",
		"--no-playlist",
		"--no-warnings",
		playURL,
	).CombinedOutput()
	if ctx.Err() == context.DeadlineExceeded {
		return "", fmt.Errorf("YouTube 解析超时（请确认已安装 yt-dlp）")
	}
	if err != nil {
		msg := strings.TrimSpace(string(out))
		if msg == "" {
			msg = err.Error()
		}
		return "", fmt.Errorf("YouTube 解析失败: %s", msg)
	}
	pick := firstHTTPURL(string(out))
	if pick == "" {
		return "", fmt.Errorf("YouTube 未返回可播地址")
	}
	return pick, nil
}

func firstHTTPURL(raw string) string {
	for _, line := range strings.Split(raw, "\n") {
		line = strings.TrimSpace(line)
		if strings.HasPrefix(line, "http://") || strings.HasPrefix(line, "https://") {
			return line
		}
	}
	return ""
}

func lookYoutubeDL() (string, error) {
	for _, name := range []string{"yt-dlp", "youtube-dl"} {
		if p, err := exec.LookPath(name); err == nil {
			return p, nil
		}
	}
	return "", fmt.Errorf("桌面 YouTube 需要 PATH 中的 yt-dlp（或 youtube-dl）")
}
