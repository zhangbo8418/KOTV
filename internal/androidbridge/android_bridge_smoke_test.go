package androidbridge

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"runtime"
	"testing"
	"time"
)

func postJSON(t *testing.T, url string, body []byte) ([]byte, int, error) {
	t.Helper()
	req, err := http.NewRequest(http.MethodPost, url, bytes.NewReader(body))
	if err != nil {
		return nil, 0, err
	}
	req.Header.Set("Content-Type", "application/json; charset=utf-8")
	client := &http.Client{Timeout: 10 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		return nil, 0, err
	}
	defer resp.Body.Close()
	b, _ := io.ReadAll(io.LimitReader(resp.Body, 2<<20))
	return b, resp.StatusCode, nil
}

func TestJarBridgeSelfCheck(t *testing.T) {
	if runtime.GOOS != "android" {
		t.Skip("android only")
	}

	payload := []byte(`{"method":"selfCheck"}`)
	b, code, err := postJSON(t, "http://127.0.0.1:9979/jar/call", payload)
	if err != nil {
		t.Skip("service not reachable: " + err.Error())
	}
	if code < 200 || code >= 300 {
		t.Fatalf("unexpected http=%d body=%s", code, string(b))
	}

	var obj struct {
		OK    bool   `json:"ok"`
		Error string `json:"error"`
	}
	if err := json.Unmarshal(b, &obj); err != nil {
		t.Fatalf("invalid json: %v body=%s", err, string(b))
	}
	if !obj.OK {
		t.Fatalf("selfCheck failed: %s", obj.Error)
	}
}

func TestSniffWithHtml(t *testing.T) {
	if runtime.GOOS != "android" {
		t.Skip("android only")
	}

	payload := []byte(`{
  "url":"https://example.com/any",
  "html":"<html><body>hello https://cdn.example.com/a/b/test.m3u8?x=y</body></html>",
  "headers":{},
  "timeoutMs":5000
}`)

	b, code, err := postJSON(t, "http://127.0.0.1:9979/sniff", payload)
	if err != nil {
		t.Skip("service not reachable: " + err.Error())
	}
	if code < 200 || code >= 300 {
		t.Fatalf("unexpected http=%d body=%s", code, string(b))
	}

	var out struct {
		URL string `json:"url"`
	}
	if err := json.Unmarshal(b, &out); err != nil {
		t.Fatalf("invalid json: %v body=%s", err, string(b))
	}
	if out.URL == "" {
		t.Fatalf("empty sniff url, body=%s", string(b))
	}
	if out.URL == "" || (out.URL != "" && (len(out.URL) < 10)) {
		t.Fatalf("sniff url too short: %q", out.URL)
	}
}

