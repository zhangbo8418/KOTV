//go:build android

package source

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"

	"github.com/bobo/KOTV/internal/model"
)

type androidPlaylistResp struct {
	OK       bool `json:"ok"`
	Error    string `json:"error"`
	Episodes []struct {
		Name string `json:"name"`
		URL  string `json:"url"`
	} `json:"episodes"`
}

func fetchPlaylistPlatform(parent context.Context, playURL string) ([]model.Episode, error) {
	playURL = strings.TrimSpace(playURL)
	if playURL == "" {
		return nil, fmt.Errorf("空播放列表地址")
	}
	b, err := json.Marshal(map[string]any{"url": playURL})
	if err != nil {
		return nil, err
	}
	timeout := 90 * time.Second
	if parent != nil {
		if dl, ok := parent.Deadline(); ok {
			if rem := time.Until(dl); rem > 0 && rem < timeout {
				timeout = rem
			}
		}
	}
	req, err := http.NewRequest(http.MethodPost, androidSourceBase+"/source/playlist", bytes.NewReader(b))
	if err != nil {
		return nil, err
	}
	if parent != nil {
		req = req.WithContext(parent)
	}
	req.Header.Set("Content-Type", "application/json")
	client := &http.Client{Timeout: timeout}
	resp, err := client.Do(req)
	if err != nil {
		return nil, fmt.Errorf("source playlist: %w", err)
	}
	defer resp.Body.Close()
	raw, err := io.ReadAll(io.LimitReader(resp.Body, 8<<20))
	if err != nil {
		return nil, err
	}
	var out androidPlaylistResp
	if err := json.Unmarshal(raw, &out); err != nil {
		return nil, fmt.Errorf("source playlist bad json: %w", err)
	}
	if !out.OK {
		msg := strings.TrimSpace(out.Error)
		if msg == "" {
			msg = "playlist expand failed"
		}
		return nil, fmt.Errorf("%s", msg)
	}
	eps := make([]model.Episode, 0, len(out.Episodes))
	for _, e := range out.Episodes {
		u := strings.TrimSpace(e.URL)
		if u == "" {
			continue
		}
		name := strings.TrimSpace(e.Name)
		if name == "" {
			name = u
		}
		eps = append(eps, model.CreateEpisode(name, u))
	}
	if len(eps) == 0 {
		return nil, fmt.Errorf("YouTube 播放列表为空")
	}
	return eps, nil
}
