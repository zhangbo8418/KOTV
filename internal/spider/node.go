package spider

import (
	"encoding/json"
	"fmt"
	"strings"
)

// nodeSpider 通过 HTTP 调用猫爪 Node 源包上的 /spider/<key>/<type>/… 接口。
type nodeSpider struct {
	key, api, ext, jar string
	pkgID              string
	prefix             string // /spider/key/type
	inited             bool
}

func newNodeSpider(key, api, ext, jar string) Spider {
	api = strings.TrimSpace(api)
	pkgID := DefaultNodeHost().PkgIDForAPI(api)
	return &nodeSpider{
		key:    key,
		api:    api,
		ext:    ext,
		jar:    jar,
		pkgID:  pkgID,
		prefix: strings.TrimSuffix(api, "/"),
	}
}

func (s *nodeSpider) pkg() (*nodePkg, error) {
	h := DefaultNodeHost()
	id := s.pkgID
	if id == "" {
		id = h.PkgIDForAPI(s.api)
		s.pkgID = id
	}
	if id == "" {
		return nil, fmt.Errorf("未找到 Node 源包: %s", s.api)
	}
	p := h.GetPkg(id)
	if p == nil {
		return nil, fmt.Errorf("Node 源包未加载: %s", id)
	}
	if p.Port() <= 0 {
		if _, err := h.Ensure(p.pkgURL); err != nil {
			return nil, err
		}
		p = h.GetPkg(id)
		if p == nil || p.Port() <= 0 {
			return nil, fmt.Errorf("Node 源包未就绪: %s", id)
		}
	}
	return p, nil
}

func (s *nodeSpider) post(action string, body map[string]any) (string, error) {
	p, err := s.pkg()
	if err != nil {
		return "", err
	}
	if body == nil {
		body = map[string]any{}
	}
	p.rememberCaller()
	path := s.prefix + "/" + action
	return p.PostJSON(path, body)
}

// nodeRouteMissing 源包未注册该动作时的 HTTP 404。
// 猫爪 Node 按方法存在才挂路由（t.home&&post/home）；推送等站无 home/search。
func nodeRouteMissing(err error) bool {
	if err == nil {
		return false
	}
	// PostJSON: "POST <path> http 404: …"
	return strings.Contains(err.Error(), " http 404:")
}

// postOptional 可选动作：无路由时当作空 JSON（兜底；推送首页在 SiteService 已跳过）。
func (s *nodeSpider) postOptional(action string, body map[string]any) (string, error) {
	raw, err := s.post(action, body)
	if nodeRouteMissing(err) {
		return "{}", nil
	}
	if err != nil {
		return "", err
	}
	if strings.TrimSpace(raw) == "" {
		return "{}", nil
	}
	return raw, nil
}

func (s *nodeSpider) Init(extend string) error {
	if extend != "" {
		s.ext = extend
	}
	body := map[string]any{}
	if strings.TrimSpace(s.ext) != "" {
		// 源包 init 常见字段 extend；对象型 ext 已是紧凑 JSON 字符串。
		var extObj any
		if err := json.Unmarshal([]byte(s.ext), &extObj); err == nil {
			body["extend"] = extObj
		} else {
			body["extend"] = s.ext
		}
	}
	_, err := s.post("init", body)
	if err != nil {
		return err
	}
	s.inited = true
	return nil
}

func (s *nodeSpider) ensureInit() error {
	if s.inited {
		return nil
	}
	return s.Init(s.ext)
}

func (s *nodeSpider) HomeContent(filter bool) (string, error) {
	if err := s.ensureInit(); err != nil {
		return "", err
	}
	return s.postOptional("home", map[string]any{"filter": filter})
}

func (s *nodeSpider) HomeVideoContent() (string, error) {
	if err := s.ensureInit(); err != nil {
		return "", err
	}
	// 猫爪包按方法挂路由：homeVod 与 homeVideo 常只实现其一（缓存包约 5 vs 16）。
	return s.postHomeVideoList()
}

// postHomeVideoList 先 homeVod；失败或空体再 homeVideo（两路由常只实现其一）。
func (s *nodeSpider) postHomeVideoList() (string, error) {
	vodRaw, vodErr := s.post("homeVod", map[string]any{})
	if vodErr == nil && strings.TrimSpace(vodRaw) != "" {
		return vodRaw, nil
	}
	videoRaw, videoErr := s.postOptional("homeVideo", map[string]any{})
	return pickHomeVideoRaw(vodRaw, vodErr, videoRaw, videoErr)
}

// pickHomeVideoRaw 合并 homeVod / homeVideo（供单测）。优先非空 body；真实错误上抛，勿软吞成 {}。
func pickHomeVideoRaw(vodRaw string, vodErr error, videoRaw string, videoErr error) (string, error) {
	if vodErr == nil && strings.TrimSpace(vodRaw) != "" {
		return vodRaw, nil
	}
	if videoErr == nil && strings.TrimSpace(videoRaw) != "" {
		return videoRaw, nil
	}
	if vodErr != nil && !nodeRouteMissing(vodErr) {
		return "", vodErr
	}
	if videoErr != nil && !nodeRouteMissing(videoErr) {
		return "", videoErr
	}
	return "{}", nil
}

func (s *nodeSpider) CategoryContent(tid, pg string, filter bool, extend map[string]string) (string, error) {
	if err := s.ensureInit(); err != nil {
		return "", err
	}
	filters := map[string]string{}
	for k, v := range extend {
		filters[k] = v
	}
	return s.postOptional("category", map[string]any{
		"id":      tid,
		"page":    pg,
		"filter":  filter,
		"filters": filters,
	})
}

func (s *nodeSpider) DetailContent(ids []string) (string, error) {
	if err := s.ensureInit(); err != nil {
		return "", err
	}
	var id any
	switch len(ids) {
	case 0:
		id = ""
	case 1:
		id = ids[0]
	default:
		id = ids
	}
	return s.post("detail", map[string]any{"id": id})
}

func (s *nodeSpider) SearchContent(key string, quick bool, pg string) (string, error) {
	if err := s.ensureInit(); err != nil {
		return "", err
	}
	if strings.TrimSpace(pg) == "" {
		pg = "1"
	}
	return s.postOptional("search", map[string]any{
		"wd":    key,
		"page":  pg,
		"quick": quick,
	})
}

func (s *nodeSpider) PlayerContent(flag, id string, vipFlags []string) (string, error) {
	if err := s.ensureInit(); err != nil {
		return "", err
	}
	body := map[string]any{
		"flag": flag,
		"id":   id,
	}
	if len(vipFlags) > 0 {
		body["flags"] = vipFlags
	}
	raw, err := s.post("play", body)
	if err != nil {
		return "", err
	}
	p, err := s.pkg()
	if err != nil {
		return raw, nil
	}
	return p.RewritePlayJSON(raw), nil
}

func (s *nodeSpider) LiveContent(url string) (string, error) { return "", nil }

func (s *nodeSpider) Proxy(params map[string]string) (int, string, []byte, map[string]string, error) {
	return 0, "", nil, nil, nil
}

func (s *nodeSpider) Action(action string) (string, error) {
	if err := s.ensureInit(); err != nil {
		return "", err
	}
	raw, err := s.postOptional("action", map[string]any{"action": action})
	if err != nil {
		return "", err
	}
	return rewriteNodeActionWeb(raw, s), nil
}

// rewriteNodeActionWeb 把 action 返回的 web.url 改成引擎可打开的地址（本机反代 / 远端带 token）。
func rewriteNodeActionWeb(raw string, s *nodeSpider) string {
	raw = strings.TrimSpace(raw)
	if raw == "" || raw == "{}" || s == nil {
		return raw
	}
	var m map[string]any
	if err := json.Unmarshal([]byte(raw), &m); err != nil {
		return raw
	}
	web, _ := m["web"].(map[string]any)
	if web == nil {
		return raw
	}
	u, _ := web["url"].(string)
	u = strings.TrimSpace(u)
	if u == "" {
		return raw
	}
	if p, err := s.pkg(); err == nil && p != nil {
		u = p.RewriteOpenWebURL(u)
	}
	web["url"] = u
	m["web"] = web
	out, err := json.Marshal(m)
	if err != nil {
		return raw
	}
	return string(out)
}

func (s *nodeSpider) ManualVideoCheck() (bool, error) { return false, nil }
func (s *nodeSpider) IsVideoFormat(string) (bool, error) {
	return false, nil
}
func (s *nodeSpider) Destroy() {}
