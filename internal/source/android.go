//go:build android

package source

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"

	"github.com/bobo/KOTV/internal/model"
)

const androidSourceBase = "http://127.0.0.1:9979"

type androidSourceResp struct {
	OK      bool   `json:"ok"`
	Error   string `json:"error"`
	URL     string `json:"url"`
	Name    string `json:"name"`
	Artwork string `json:"artwork"`
	Desc    string `json:"desc"`
	Subs    []struct {
		URL    string `json:"url"`
		Name   string `json:"name"`
		Lang   string `json:"lang"`
		Format string `json:"format"`
	} `json:"subs"`
}

func fetchPlatformInfo(playURL string, core json.RawMessage) (Info, error) {
	body := map[string]any{"url": playURL}
	if len(core) > 0 && string(core) != "null" {
		var raw any
		if err := json.Unmarshal(core, &raw); err == nil {
			body["core"] = raw
		}
	}
	b, err := json.Marshal(body)
	if err != nil {
		return Info{}, err
	}
	req, err := http.NewRequest(http.MethodPost, androidSourceBase+"/source/fetch", bytes.NewReader(b))
	if err != nil {
		return Info{}, err
	}
	req.Header.Set("Content-Type", "application/json")
	client := &http.Client{Timeout: 40 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		return Info{}, fmt.Errorf("source fetch: %w", err)
	}
	defer resp.Body.Close()
	raw, err := io.ReadAll(resp.Body)
	if err != nil {
		return Info{}, err
	}
	var out androidSourceResp
	if err := json.Unmarshal(raw, &out); err != nil {
		return Info{}, fmt.Errorf("source fetch bad json: %w (%s)", err, string(raw))
	}
	if !out.OK {
		msg := strings.TrimSpace(out.Error)
		if msg == "" {
			msg = "source fetch failed"
		}
		return Info{}, fmt.Errorf("%s", msg)
	}
	u := strings.TrimSpace(out.URL)
	if u == "" {
		return Info{}, fmt.Errorf("source 返回空地址")
	}
	info := Info{
		URL:     u,
		Name:    strings.TrimSpace(out.Name),
		Artwork: strings.TrimSpace(out.Artwork),
		Desc:    strings.TrimSpace(out.Desc),
	}
	for _, s := range out.Subs {
		su := strings.TrimSpace(s.URL)
		if su == "" {
			continue
		}
		name := strings.TrimSpace(s.Name)
		if name == "" {
			name = strings.TrimSpace(s.Lang)
		}
		fmtName := strings.TrimSpace(s.Format)
		if fmtName == "" {
			fmtName = "text/vtt"
		}
		info.Subs = append(info.Subs, model.Sub{
			URL:    su,
			Name:   name,
			Lang:   strings.TrimSpace(s.Lang),
			Format: fmtName,
		})
	}
	return info, nil
}

func stopPlatform() {
	req, err := http.NewRequest(http.MethodPost, androidSourceBase+"/source/stop", bytes.NewReader([]byte("{}")))
	if err != nil {
		return
	}
	req.Header.Set("Content-Type", "application/json")
	client := &http.Client{Timeout: 5 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		return
	}
	io.Copy(io.Discard, resp.Body)
	resp.Body.Close()
}
