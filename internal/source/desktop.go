//go:build !android

package source

import (
	"context"
	"encoding/json"
	"fmt"
	"net/url"
	"os/exec"
	"sort"
	"strings"
	"time"

	"github.com/bobo/KOTV/internal/model"
)

func fetchPlatformInfo(playURL string, _ json.RawMessage) (Info, error) {
	playURL = strings.TrimSpace(playURL)
	if playURL == "" {
		return Info{}, fmt.Errorf("空播放地址")
	}
	u, err := url.Parse(playURL)
	if err != nil {
		return Info{}, err
	}
	scheme := strings.ToLower(u.Scheme)
	host := strings.ToLower(u.Hostname())

	switch {
	case strings.Contains(host, "youtube.com") || strings.Contains(host, "youtu.be"):
		return fetchYouTubeDesktopInfo(playURL)
	case scheme == "jianpian" || scheme == "tvbox-xg" || scheme == "xg" || scheme == "xgplay" || scheme == "ftp":
		return Info{}, fmt.Errorf("荐片 P2P 仅安卓支持（需 libjpa）: %s", playURL)
	case scheme == "tvbus":
		return Info{}, fmt.Errorf("TVBus 仅安卓支持: %s", playURL)
	case isForceScheme(scheme):
		return Info{}, fmt.Errorf("ForceTech (%s) 仅安卓支持: %s", scheme, playURL)
	default:
		return Info{}, fmt.Errorf("桌面不支持该源协议: %s", playURL)
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

// fetchYouTubeDesktopInfo 用 PATH 里的 yt-dlp / youtube-dl 解析可播直链，并尽量带回标题/封面/字幕。
func fetchYouTubeDesktopInfo(playURL string) (Info, error) {
	bin, err := lookYoutubeDL()
	if err != nil {
		return Info{}, err
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
		return Info{}, fmt.Errorf("YouTube 解析超时（请确认已安装 yt-dlp）")
	}
	if err != nil {
		msg := strings.TrimSpace(string(out))
		if msg == "" {
			msg = err.Error()
		}
		return Info{}, fmt.Errorf("YouTube 解析失败: %s", msg)
	}
	pick := firstHTTPURL(string(out))
	if pick == "" {
		return Info{}, fmt.Errorf("YouTube 未返回可播地址")
	}
	info := Info{URL: pick}
	// 元数据/字幕失败不影响起播。
	fillYouTubeDesktopMeta(ctx, bin, playURL, &info)
	return info, nil
}

type ytDLPSubTrack struct {
	URL string `json:"url"`
	Ext string `json:"ext"`
}

type ytDLPMeta struct {
	Title              string                     `json:"title"`
	Thumbnail          string                     `json:"thumbnail"`
	Description        string                     `json:"description"`
	Subtitles          map[string][]ytDLPSubTrack `json:"subtitles"`
	AutomaticCaptions  map[string][]ytDLPSubTrack `json:"automatic_captions"`
}

func fillYouTubeDesktopMeta(parent context.Context, bin, playURL string, info *Info) {
	if info == nil || bin == "" || playURL == "" {
		return
	}
	ctx, cancel := context.WithTimeout(parent, 20*time.Second)
	defer cancel()
	out, err := exec.CommandContext(ctx, bin,
		"-j",
		"--skip-download",
		"--no-playlist",
		"--no-warnings",
		playURL,
	).Output()
	if err != nil || len(out) == 0 {
		return
	}
	var meta ytDLPMeta
	if err := json.Unmarshal(out, &meta); err != nil {
		return
	}
	info.Name = strings.TrimSpace(meta.Title)
	info.Artwork = strings.TrimSpace(meta.Thumbnail)
	info.Desc = strings.TrimSpace(meta.Description)
	info.Subs = ytDLPSubs(meta.Subtitles, meta.AutomaticCaptions)
}

func ytDLPSubs(manual, auto map[string][]ytDLPSubTrack) []model.Sub {
	out := pickYTDLPSubs(manual)
	if len(out) == 0 {
		out = pickYTDLPSubs(auto)
	}
	return out
}

func pickYTDLPSubs(byLang map[string][]ytDLPSubTrack) []model.Sub {
	if len(byLang) == 0 {
		return nil
	}
	langs := make([]string, 0, len(byLang))
	for lang := range byLang {
		langs = append(langs, lang)
	}
	sort.Strings(langs)
	var out []model.Sub
	for _, lang := range langs {
		tracks := byLang[lang]
		u, fmtName := pickYTDLPSubURL(tracks)
		if u == "" {
			continue
		}
		name := lang
		out = append(out, model.Sub{
			URL:    u,
			Name:   name,
			Lang:   lang,
			Format: fmtName,
		})
		if len(out) >= 12 {
			break
		}
	}
	return out
}

func pickYTDLPSubURL(tracks []ytDLPSubTrack) (url, format string) {
	prefer := []string{"vtt", "srt", "ttml", "srv3", "srv2", "srv1"}
	for _, ext := range prefer {
		for _, t := range tracks {
			if strings.EqualFold(strings.TrimSpace(t.Ext), ext) {
				u := strings.TrimSpace(t.URL)
				if u != "" {
					return u, mimeForSubExt(ext)
				}
			}
		}
	}
	for _, t := range tracks {
		u := strings.TrimSpace(t.URL)
		if u == "" {
			continue
		}
		return u, mimeForSubExt(t.Ext)
	}
	return "", ""
}

func mimeForSubExt(ext string) string {
	switch strings.ToLower(strings.TrimSpace(ext)) {
	case "vtt":
		return "text/vtt"
	case "srt":
		return "application/x-subrip"
	case "ttml", "xml":
		return "application/ttml+xml"
	default:
		return "text/vtt"
	}
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
