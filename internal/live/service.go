package live

import (
	"fmt"
	"strings"
	"sync"

	"github.com/bobo/KOTV/internal/config"
	"github.com/bobo/KOTV/internal/model"
	parsepkg "github.com/bobo/KOTV/internal/parse"
	"github.com/bobo/KOTV/internal/settings"
	"github.com/bobo/KOTV/internal/spider"
	"github.com/bobo/KOTV/internal/util"
)

// Service 直播服务。
type Service struct {
	mu      sync.RWMutex
	cfg     *config.Manager
	current *model.Live
	sources []model.Live
}

func NewService(cfg *config.Manager) *Service {
	return &Service{cfg: cfg}
}

// Sources 可用直播源列表（配置 + 设置自定义）。
func (s *Service) Sources() []model.Live {
	s.mu.RLock()
	defer s.mu.RUnlock()
	out := make([]model.Live, len(s.sources))
	copy(out, s.sources)
	return out
}

func (s *Service) Current() *model.Live {
	s.mu.RLock()
	defer s.mu.RUnlock()
	return s.current
}

// SyncFromConfig 从 ApiConfig + 设置同步直播源。
func (s *Service) SyncFromConfig() {
	var sources []model.Live
	api := s.cfg.API()
	for _, l := range api.Lives {
		sources = append(sources, l)
	}
	if custom := strings.TrimSpace(settings.Get(settings.LIVE)); custom != "" {
		found := false
		for _, l := range sources {
			if l.URL == custom {
				found = true
				break
			}
		}
		if !found {
			sources = append([]model.Live{{
				Name: "自定义",
				URL:  custom,
			}}, sources...)
		}
	}
	s.mu.Lock()
	s.sources = sources
	s.mu.Unlock()
}

// Load 加载指定直播源频道列表。
func (s *Service) Load(live model.Live) (*model.Live, error) {
	if live.URL == "" && strings.TrimSpace(live.API) == "" {
		return nil, fmt.Errorf("直播源地址为空")
	}
	text, err := s.fetchLiveText(live)
	if err != nil {
		return nil, err
	}
	live.Groups = nil
	Parse(&live, text)
	if len(live.Groups) == 0 {
		return nil, fmt.Errorf("未解析到频道")
	}
	s.mu.Lock()
	s.current = &live
	s.mu.Unlock()
	return &live, nil
}

// fetchLiveText csp/js/py 直播源走 spider.liveContent，否则直接 HTTP。
func (s *Service) fetchLiveText(live model.Live) (string, error) {
	if api := strings.TrimSpace(live.API); api != "" {
		ext := live.Ext.String()
		sp := spider.Get(live.Name, api, ext, live.JAR)
		if err := sp.Init(ext); err != nil {
			return "", fmt.Errorf("直播源初始化失败: %w", err)
		}
		spider.SetRecent(live.Name, api, ext, live.JAR)
		text, err := sp.LiveContent(live.URL)
		if err != nil {
			return "", fmt.Errorf("直播源 liveContent 失败: %w", err)
		}
		return text, nil
	}
	text, err := util.HTTPGet(live.URL, live.Headers())
	if err != nil {
		return "", fmt.Errorf("下载直播源失败: %w", err)
	}
	return text, nil
}

// ResolvePlayURL 解析频道当前线路播放地址（不去二次解析）。
func ResolvePlayURL(ch *model.LiveChannel) (string, map[string]string) {
	if ch == nil {
		return "", nil
	}
	raw := ch.CurrentURL()
	headers := ch.BuildHeaders()
	raw = stripDecorators(raw, headers)
	return raw, headers
}

// ResolvePlayURLParsed 带二次解析的直播地址解析。
func (s *Service) ResolvePlayURLParsed(ch *model.LiveChannel) (string, map[string]string, error) {
	if ch == nil {
		return "", nil, fmt.Errorf("频道为空")
	}
	raw := ch.CurrentURL()
	headers := ch.BuildHeaders()
	raw = stripDecorators(raw, headers)

	needParse := ch.Parse == 1 ||
		strings.HasPrefix(raw, "json:") ||
		strings.HasPrefix(raw, "parse:") ||
		strings.HasPrefix(raw, "video://")
	if strings.HasPrefix(raw, "video://") {
		raw = strings.TrimPrefix(raw, "video://")
		needParse = true
	}

	var parses []model.Parse
	if s.cfg != nil {
		parses = s.cfg.API().Parses
	}
	out, err := parsepkg.ResolveLiveURL(raw, needParse, parses, headers)
	if err != nil {
		return raw, headers, err
	}
	if out == "" {
		out = raw
	}
	return out, headers, nil
}

func stripDecorators(u string, headers map[string]string) string {
	// url@Referer=xxx@User-Agent=yyy
	if !strings.Contains(u, "@") {
		return u
	}
	parts := strings.Split(u, "@")
	base := parts[0]
	for _, p := range parts[1:] {
		kv := strings.SplitN(p, "=", 2)
		if len(kv) != 2 {
			continue
		}
		key := strings.TrimSpace(kv[0])
		val := strings.TrimSpace(kv[1])
		switch strings.ToLower(key) {
		case "referer", "user-agent", "origin", "cookie":
			if headers == nil {
				headers = make(map[string]string)
			}
			switch strings.ToLower(key) {
			case "user-agent":
				headers["User-Agent"] = val
			case "referer":
				headers["Referer"] = val
			case "origin":
				headers["Origin"] = val
			case "cookie":
				headers["Cookie"] = val
			}
		}
	}
	return base
}
