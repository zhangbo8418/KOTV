//go:build android

package thunder

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"strings"
	"time"

	"github.com/bobo/KOTV/internal/model"
)

const androidThunderBase = "http://127.0.0.1:9979"

type androidThunderFile struct {
	Name    string `json:"name"`
	Index   int    `json:"index"`
	Size    int64  `json:"size"`
	PlayURL string `json:"playUrl"`
}

type androidThunderResp struct {
	OK      bool                 `json:"ok"`
	Error   string               `json:"error"`
	URL     string               `json:"url"`
	Files   []androidThunderFile `json:"files"`
	Phase   string               `json:"phase"`
	Peers   int                  `json:"peers"`
	Bytes   int64                `json:"bytes"`
	Need    int64                `json:"need"`
	Message string               `json:"message"`
}

func androidThunderPOST(path string, body any) (*androidThunderResp, error) {
	var rdr io.Reader
	if body != nil {
		b, err := json.Marshal(body)
		if err != nil {
			return nil, err
		}
		rdr = bytes.NewReader(b)
	} else {
		rdr = bytes.NewReader([]byte("{}"))
	}
	req, err := http.NewRequest(http.MethodPost, androidThunderBase+path, rdr)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/json")
	client := &http.Client{Timeout: 90 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	raw, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, err
	}
	var out androidThunderResp
	if err := json.Unmarshal(raw, &out); err != nil {
		return nil, fmt.Errorf("android thunder bad json: %w (%s)", err, string(raw))
	}
	return &out, nil
}

// tryAndroidParse 走 Native 迅雷；Android 无 anacrolix 回落。
func tryAndroidParse(raw string) ([]model.Episode, error) {
	out, err := androidThunderPOST("/thunder/parse", map[string]string{"url": raw})
	if err != nil {
		return nil, fmt.Errorf("迅雷解析失败: %w", err)
	}
	if !out.OK {
		msg := strings.TrimSpace(out.Error)
		if msg == "" {
			msg = "迅雷解析失败"
		}
		return nil, fmt.Errorf("%s", msg)
	}
	eps := make([]model.Episode, 0, len(out.Files))
	for _, f := range out.Files {
		u := strings.TrimSpace(f.PlayURL)
		if u == "" {
			continue
		}
		name := strings.TrimSpace(f.Name)
		if name == "" {
			name = fmt.Sprintf("文件%d", f.Index+1)
		}
		eps = append(eps, model.Episode{Name: name, URL: u})
	}
	if len(eps) == 0 {
		return nil, fmt.Errorf("迅雷：未找到可播媒体文件")
	}
	log.Printf("thunder: android/xunlei parse ok files=%d", len(eps))
	return eps, nil
}

func tryAndroidFetch(raw string) (string, error) {
	setProgress("meta", 0, 0, 0, "迅雷获取中…")
	out, err := androidThunderPOST("/thunder/fetch", map[string]string{"url": raw})
	if err != nil {
		setProgress("error", 0, 0, 0, err.Error())
		return "", fmt.Errorf("迅雷起播失败: %w", err)
	}
	if !out.OK {
		msg := strings.TrimSpace(out.Error)
		if msg == "" {
			msg = "迅雷起播失败"
		}
		setProgress("error", 0, 0, 0, msg)
		return "", fmt.Errorf("%s", msg)
	}
	u := strings.TrimSpace(out.URL)
	if u == "" {
		setProgress("error", 0, 0, 0, "迅雷返回空地址")
		return "", fmt.Errorf("迅雷返回空播放地址")
	}
	setProgress("ready", out.Peers, out.Bytes, out.Need, "迅雷就绪")
	log.Printf("thunder: android/xunlei fetch ok url=%s", shorten(u))
	return u, nil
}

func tryAndroidProgress() (FetchProgress, bool) {
	out, err := androidThunderPOST("/thunder/progress", nil)
	if err != nil || out == nil {
		return FetchProgress{}, false
	}
	if out.Phase == "" || out.Phase == "idle" {
		return FetchProgress{}, false
	}
	return FetchProgress{
		Phase:   out.Phase,
		Peers:   out.Peers,
		Bytes:   out.Bytes,
		Need:    out.Need,
		Message: out.Message,
	}, true
}

func tryAndroidClear() {
	_, _ = androidThunderPOST("/thunder/clear", nil)
}

func stopPlatform() {
	// 对齐 TV Thunder.stop：deleteTask + release，打断阻塞中的 fetch 轮询。
	tryAndroidClear()
}

// ParseContext 在 Android 上仅走迅雷 Native。
func ParseContext(_ context.Context, raw string) ([]model.Episode, error) {
	raw = Decode(strings.TrimSpace(raw))
	return tryAndroidParse(raw)
}

// Fetch 在 Android 上仅走迅雷 SDK（magnet / thunder / ed2k / ftp 等）。
func Fetch(raw string) (string, error) {
	raw = Decode(strings.TrimSpace(raw))
	// 对齐 TV playerContent 前 Source.stop：先停旧任务再起新 Fetch。
	stopPlatform()
	return tryAndroidFetch(raw)
}

// ClearStorage 清理 Android 迅雷缓存。
func ClearStorage() (int64, error) {
	tryAndroidClear()
	setProgress("idle", 0, 0, 0, "磁力缓存已清理")
	log.Printf("thunder: android/xunlei storage cleared")
	return 0, nil
}

// Handle：Android 播放由迅雷 Native 提供地址，不走 anacrolix 本地 /proxy/bt/。
func Handle(w http.ResponseWriter, r *http.Request) {
	http.Error(w, "android uses xunlei native streaming", http.StatusNotImplemented)
}
