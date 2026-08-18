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
)

const androidSourceBase = "http://127.0.0.1:9979"

type androidSourceResp struct {
	OK    bool   `json:"ok"`
	Error string `json:"error"`
	URL   string `json:"url"`
}

func fetchPlatform(playURL string, core json.RawMessage) (string, error) {
	body := map[string]any{"url": playURL}
	if len(core) > 0 && string(core) != "null" {
		var raw any
		if err := json.Unmarshal(core, &raw); err == nil {
			body["core"] = raw
		}
	}
	b, err := json.Marshal(body)
	if err != nil {
		return "", err
	}
	req, err := http.NewRequest(http.MethodPost, androidSourceBase+"/source/fetch", bytes.NewReader(b))
	if err != nil {
		return "", err
	}
	req.Header.Set("Content-Type", "application/json")
	client := &http.Client{Timeout: 40 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		return "", fmt.Errorf("source fetch: %w", err)
	}
	defer resp.Body.Close()
	raw, err := io.ReadAll(resp.Body)
	if err != nil {
		return "", err
	}
	var out androidSourceResp
	if err := json.Unmarshal(raw, &out); err != nil {
		return "", fmt.Errorf("source fetch bad json: %w (%s)", err, string(raw))
	}
	if !out.OK {
		msg := strings.TrimSpace(out.Error)
		if msg == "" {
			msg = "source fetch failed"
		}
		return "", fmt.Errorf("%s", msg)
	}
	u := strings.TrimSpace(out.URL)
	if u == "" {
		return "", fmt.Errorf("source 返回空地址")
	}
	return u, nil
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
