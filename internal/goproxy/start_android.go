//go:build android

package goproxy

import (
	"io"
	"net/http"
	"strings"
	"time"
)

const androidGoStartURL = "http://127.0.0.1:9979/go/start"

func startSidecarPlatform() error {
	client := &http.Client{Timeout: 8 * time.Second}
	req, err := http.NewRequest(http.MethodPost, androidGoStartURL, strings.NewReader("{}"))
	if err != nil {
		return err
	}
	req.Header.Set("Content-Type", "application/json; charset=utf-8")
	resp, err := client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	_, _ = io.Copy(io.Discard, io.LimitReader(resp.Body, 4096))
	if resp.StatusCode >= 400 {
		return errHTTPStatus{resp.StatusCode}
	}
	return nil
}

type errHTTPStatus struct{ code int }

func (e errHTTPStatus) Error() string { return http.StatusText(e.code) }
