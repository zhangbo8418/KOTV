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
	"github.com/bobo/KOTV/internal/model"
	"github.com/bobo/KOTV/internal/util"
)

const (
	maxDataURILength   = 8 * 1024 * 1024
	imageCacheMaxItems = 64
	imageCacheMaxBytes = 32 << 20 // 32MB
)

var (
	imageMIME = regexp.MustCompile(`(?i)^image/[a-z0-9.+-]+$`)

	imageMu     sync.Mutex
	imageByKey  = map[string]cachedImage{}
	imageOrder  []string // 最旧在前
	imageBytes  int
)

type cachedImage struct {
	mime string
	data []byte
}

// ClearImageCache 清空内存封面/dataURI 缓存（清理缓存工具）。
func ClearImageCache() {
	imageMu.Lock()
	defer imageMu.Unlock()
	imageByKey = map[string]cachedImage{}
	imageOrder = nil
	imageBytes = 0
}

func imageStore(key string, img cachedImage) {
	imageMu.Lock()
	defer imageMu.Unlock()
	if old, ok := imageByKey[key]; ok {
		imageBytes -= len(old.data)
		for i, k := range imageOrder {
			if k == key {
				imageOrder = append(imageOrder[:i], imageOrder[i+1:]...)
				break
			}
		}
	}
	imageByKey[key] = img
	imageOrder = append(imageOrder, key)
	imageBytes += len(img.data)
	for (len(imageByKey) > imageCacheMaxItems || imageBytes > imageCacheMaxBytes) && len(imageOrder) > 0 {
		victim := imageOrder[0]
		imageOrder = imageOrder[1:]
		if v, ok := imageByKey[victim]; ok {
			imageBytes -= len(v.data)
			delete(imageByKey, victim)
		}
	}
}

func imageLoad(key string) (cachedImage, bool) {
	imageMu.Lock()
	defer imageMu.Unlock()
	img, ok := imageByKey[key]
	if !ok {
		return cachedImage{}, false
	}
	// 命中挪到尾部
	for i, k := range imageOrder {
		if k == key {
			imageOrder = append(append(imageOrder[:i], imageOrder[i+1:]...), key)
			break
		}
	}
	return img, true
}

// CacheDataURI 把 data: 图片写入内存并返回 /image/{md5}；其它地址原样返回。
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
	if _, ok := imageLoad(key); !ok {
		img := decodeDataURI(url)
		if img == nil {
			return ""
		}
		imageStore(key, *img)
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
		img, ok := imageLoad(key)
		if !ok {
			http.NotFound(w, r)
			return
		}
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
		imageStore(key, cachedImage{mime: mime, data: body})
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
	_, _ = w.Write([]byte(s.tvbusResp()))
}

// tvbusResp LiveConfig.getResp：当前直播源 core.resp（http 则拉取）。
func (s *Server) tvbusResp() string {
	s.mu.RLock()
	fn := s.tvbusRespFn
	s.mu.RUnlock()
	if fn != nil {
		if out := fn(); out != "" {
			return out
		}
	}
	return resolveCoreResp(config.Default().API().Lives, nil)
}

// ResolveCoreResp 从 live 列表解析 core.resp；prefer 非空时优先匹配同名项。
func ResolveCoreResp(lives []model.Live, prefer *model.Live) string {
	return resolveCoreResp(lives, prefer)
}

func resolveCoreResp(lives []model.Live, prefer *model.Live) string {
	var candidates []model.Live
	if prefer != nil {
		candidates = append(candidates, *prefer)
		name := strings.TrimSpace(prefer.Name)
		url := strings.TrimSpace(prefer.URL)
		for _, l := range lives {
			if name != "" && strings.TrimSpace(l.Name) == name {
				candidates = append(candidates, l)
				break
			}
			if url != "" && strings.TrimSpace(l.URL) == url {
				candidates = append(candidates, l)
				break
			}
		}
	}
	candidates = append(candidates, lives...)
	for _, live := range candidates {
		if out := coreRespString(live.Core); out != "" {
			return out
		}
	}
	return ""
}

func coreRespString(coreRaw json.RawMessage) string {
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
