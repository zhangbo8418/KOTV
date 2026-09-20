package server

import (
	"crypto/md5"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"io"
	"net/http"
	"regexp"
	"strings"
	"sync"

	"github.com/bobo/KOTV/internal/config"
	"github.com/bobo/KOTV/internal/util"
)

const maxDataURILength = 8 * 1024 * 1024

var (
	imageMIME   = regexp.MustCompile(`(?i)^image/[a-z0-9.+-]+$`)
	imageCache  sync.Map // key(md5) -> cachedImage
)

type cachedImage struct {
	mime string
	data []byte
}

// CacheDataURI ImgUtil.cache：data: → 写入内存并返回 /image/{md5} 相对路径；非 data: 原样返回。
func CacheDataURI(url string) string {
	url = strings.TrimSpace(url)
	if url == "" {
		return ""
	}
	if !strings.HasPrefix(strings.ToLower(url), "data:") {
		return url
	}
	if len(url) > maxDataURILength {
		return ""
	}
	sum := md5.Sum([]byte(url))
	key := hex.EncodeToString(sum[:])
	if key == "" {
		return ""
	}
	if _, ok := imageCache.Load(key); !ok {
		img := decodeDataURI(url)
		if img == nil {
			return ""
		}
		imageCache.Store(key, *img)
	}
	return "/image/" + key
}

func decodeDataURI(url string) *cachedImage {
	// data:[<mime>][;base64],<data>
	if len(url) < 6 || !strings.HasPrefix(strings.ToLower(url), "data:") {
		return nil
	}
	comma := strings.IndexByte(url, ',')
	if comma < 0 {
		return nil
	}
	metadata := strings.ToLower(url[5:comma])
	parts := strings.SplitN(metadata, ";", 2)
	mime := parts[0]
	if !imageMIME.MatchString(mime) || !strings.HasSuffix(metadata, ";base64") {
		return nil
	}
	raw, err := base64.StdEncoding.DecodeString(url[comma+1:])
	if err != nil || len(raw) == 0 {
		return nil
	}
	return &cachedImage{mime: mime, data: raw}
}

func (s *Server) handleImage(w http.ResponseWriter, r *http.Request) {
	key := strings.TrimPrefix(r.URL.Path, "/image/")
	key = strings.TrimSpace(key)
	if key == "" || key == r.URL.Path {
		http.NotFound(w, r)
		return
	}
	switch r.Method {
	case http.MethodGet, http.MethodHead:
		v, ok := imageCache.Load(key)
		if !ok {
			http.NotFound(w, r)
			return
		}
		img := v.(cachedImage)
		w.Header().Set("Content-Type", img.mime)
		w.Header().Set("Content-Length", itoaLen(len(img.data)))
		if r.Method == http.MethodHead {
			w.WriteHeader(http.StatusOK)
			return
		}
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write(img.data)
	case http.MethodPut, http.MethodPost:
		// 跨进程：Android KotvImgUtil.cache 解码后写入
		mime := r.Header.Get("Content-Type")
		if mime == "" {
			mime = "application/octet-stream"
		}
		if i := strings.IndexByte(mime, ';'); i >= 0 {
			mime = strings.TrimSpace(mime[:i])
		}
		body, err := io.ReadAll(io.LimitReader(r.Body, maxDataURILength))
		if err != nil || len(body) == 0 {
			http.Error(w, "empty body", http.StatusBadRequest)
			return
		}
		imageCache.Store(key, cachedImage{mime: mime, data: body})
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("OK"))
	default:
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
	}
}

func itoaLen(n int) string {
	if n == 0 {
		return "0"
	}
	var b [20]byte
	i := len(b)
	for n > 0 {
		i--
		b[i] = byte('0' + n%10)
		n /= 10
	}
	return string(b[i:])
}

func (s *Server) handleTvbus(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write([]byte(tvbusResp()))
}

// tvbusResp LiveConfig.getResp：首页直播源 core.resp（http 则拉取）。
func tvbusResp() string {
	lives := config.Default().API().Lives
	if len(lives) == 0 {
		return ""
	}
	coreRaw := lives[0].Core
	if len(coreRaw) == 0 {
		return ""
	}
	var core struct {
		Resp string `json:"resp"`
	}
	if err := json.Unmarshal(coreRaw, &core); err != nil {
		return ""
	}
	resp := strings.TrimSpace(core.Resp)
	if resp == "" {
		return ""
	}
	lower := strings.ToLower(resp)
	if strings.HasPrefix(lower, "http://") || strings.HasPrefix(lower, "https://") {
		data, err := util.HTTPGet(resp, nil)
		if err != nil {
			return ""
		}
		return data
	}
	return resp
}
