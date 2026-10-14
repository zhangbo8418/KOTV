//go:build !android

package source

import (
	"bufio"
	"context"
	"encoding/json"
	"fmt"
	"os/exec"
	"strings"
	"time"

	"github.com/bobo/KOTV/internal/model"
)

func fetchPlaylistPlatform(parent context.Context, playURL string) ([]model.Episode, error) {
	bin, err := lookYoutubeDL()
	if err != nil {
		return nil, err
	}
	if parent == nil {
		parent = context.Background()
	}
	ctx, cancel := context.WithTimeout(parent, 90*time.Second)
	defer cancel()

	cmd := exec.CommandContext(ctx, bin,
		"--flat-playlist",
		"-j",
		"--no-download",
		"--no-warnings",
		playURL,
	)
	out, err := cmd.StdoutPipe()
	if err != nil {
		return nil, err
	}
	var stderr strings.Builder
	cmd.Stderr = &stderr
	if err := cmd.Start(); err != nil {
		return nil, err
	}

	var eps []model.Episode
	sc := bufio.NewScanner(out)
	sc.Buffer(make([]byte, 0, 64*1024), 2*1024*1024)
	for sc.Scan() {
		line := strings.TrimSpace(sc.Text())
		if line == "" {
			continue
		}
		var row struct {
			ID       string  `json:"id"`
			Title    string  `json:"title"`
			URL      string  `json:"url"`
			Webpage  string  `json:"webpage_url"`
			Duration float64 `json:"duration"`
		}
		if json.Unmarshal([]byte(line), &row) != nil {
			continue
		}
		// 直播/未完成条目 duration 常为 0 或缺失；仅跳过明确的 -1（与 NewPipe 一致）。
		if row.Duration < 0 {
			continue
		}
		u := strings.TrimSpace(row.URL)
		if u == "" {
			u = strings.TrimSpace(row.Webpage)
		}
		if u == "" && row.ID != "" {
			u = "https://www.youtube.com/watch?v=" + row.ID
		}
		if u == "" {
			continue
		}
		name := strings.TrimSpace(row.Title)
		if name == "" {
			name = row.ID
		}
		if name == "" {
			name = u
		}
		eps = append(eps, model.CreateEpisode(name, u))
	}
	waitErr := cmd.Wait()
	if ctx.Err() == context.DeadlineExceeded {
		return nil, fmt.Errorf("YouTube 播放列表解析超时")
	}
	if len(eps) == 0 {
		msg := strings.TrimSpace(stderr.String())
		if waitErr != nil && msg != "" {
			return nil, fmt.Errorf("YouTube 播放列表解析失败: %s", msg)
		}
		if waitErr != nil {
			return nil, waitErr
		}
		return nil, fmt.Errorf("YouTube 播放列表为空")
	}
	return eps, nil
}
