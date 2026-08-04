package parse

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"runtime"
	"strings"
	"sync"
	"time"

	"github.com/chromedp/cdproto/emulation"
	"github.com/chromedp/cdproto/fetch"
	"github.com/chromedp/cdproto/network"
	"github.com/chromedp/chromedp"

	"github.com/bobo/KOTV/internal/model"
	appruntime "github.com/bobo/KOTV/internal/runtime"
	"github.com/bobo/KOTV/internal/util"
)

// 网页嗅探总超时（秒级）；冷启动 Chromium 也算在这段时间内。
const defaultParseWebTimeout = 15 * time.Second

// 对齐 TV CustomWebView.MAX_URLS：嵌套 player 页最多跟进 5 个竞速。
const maxNestedPlayers = 5

// 桌面共享一个 Chromium 进程；最多 2 个并发 tab，避免超级解析打出几十个 chrome。
var (
	sharedAllocOnce   sync.Once
	sharedAllocCtx    context.Context
	sharedAllocCancel context.CancelFunc
	sharedAllocErr    error
	sniffSem          = make(chan struct{}, 2)
)

func ensureSharedChromium() (context.Context, error) {
	sharedAllocOnce.Do(func() {
		chrome := appruntime.Chromium()
		if chrome == "" {
			sharedAllocErr = fmt.Errorf("未找到 Chromium：网页嗅探不可用（请检查 runtime/chromium）")
			return
		}
		opts := append(chromedp.DefaultExecAllocatorOptions[:],
			chromedp.Flag("headless", "new"),
			chromedp.Flag("disable-gpu", true),
			chromedp.Flag("no-sandbox", true),
			chromedp.Flag("disable-dev-shm-usage", true),
			chromedp.Flag("mute-audio", true),
			chromedp.Flag("hide-scrollbars", true),
			chromedp.Flag("autoplay-policy", "no-user-gesture-required"),
			// 降低自动化特征，避免部分播放页在 headless 下不发流。
			chromedp.Flag("disable-blink-features", "AutomationControlled"),
			chromedp.Flag("disable-infobars", true),
			chromedp.Flag("enable-features", "NetworkService,NetworkServiceInProcess"),
			chromedp.ExecPath(chrome),
		)
		if runtime.GOOS == "windows" {
			opts = append(opts,
				chromedp.Flag("disable-software-rasterizer", true),
				chromedp.Flag("disable-extensions", true),
				chromedp.Flag("disable-background-networking", true),
				chromedp.Flag("disable-background-timer-throttling", true),
				chromedp.Flag("disable-renderer-backgrounding", true),
				chromedp.Flag("disable-features", "TranslateUI,BlinkGenPropertyTrees,IsolateOrigins,site-per-process"),
				chromedp.WindowSize(800, 600),
				chromedp.Flag("window-position", "-32000,-32000"),
			)
		}
		sharedAllocCtx, sharedAllocCancel = chromedp.NewExecAllocator(context.Background(), opts...)
	})
	return sharedAllocCtx, sharedAllocErr
}

// BrowserSniff 用无头 Chromium 拦截网络请求嗅探媒体地址。
func BrowserSniff(pageURL string, headers map[string]string, timeout time.Duration) (string, error) {
	return BrowserSniffWithClick(pageURL, headers, "", nil, timeout)
}

// BrowserSniffWithClick 嗅探媒体地址，可选执行 click / 规则脚本，并应用请求头。
func BrowserSniffWithClick(pageURL string, headers map[string]string, click string, rules []model.Rule, timeout time.Duration) (string, error) {
	u, _, err := browserSniff(pageURL, headers, click, rules, timeout, true, nil, 0)
	return u, err
}

type sniffHit struct {
	url     string
	headers map[string]string
}

func browserSniff(pageURL string, headers map[string]string, click string, rules []model.Rule, timeout time.Duration, detect bool, isVideo func(string) bool, depth int) (string, map[string]string, error) {
	pageURL = strings.TrimSpace(pageURL)
	if pageURL == "" {
		return "", nil, nil
	}
	start := time.Now()
	parseLog("[sniff] start depth=%d detect=%v timeout=%s click=%q url=%s", depth, detect, timeout, click, parsePreview(pageURL, 160))
	videoOK := func(u string) bool {
		if isVideo != nil {
			return isVideo(u)
		}
		return IsVideoFormatRules(u, rules)
	}
	if videoOK(pageURL) {
		parseLog("[sniff] url already video depth=%d url=%s", depth, parsePreview(pageURL, 160))
		return pageURL, cloneHeaderMap(headers), nil
	}
	if timeout <= 0 {
		timeout = defaultParseWebTimeout // 与常见网页解析超时一致：15s
	}

	// Android：不用 Chromium / chromedp；改走本地 Native Service(WebView)嗅探。
	if runtime.GOOS == "android" {
		u, h, err := androidBrowserSniff(pageURL, headers, click, rules, GetAds(), timeout, detect, videoOK)
		if err != nil {
			parseLog("[sniff] android fail depth=%d err=%v cost=%s", depth, err, time.Since(start).Truncate(time.Millisecond))
		} else {
			parseLog("[sniff] android ok depth=%d out=%s cost=%s", depth, parsePreview(u, 160), time.Since(start).Truncate(time.Millisecond))
		}
		return u, h, err
	}

	allocCtx, err := ensureSharedChromium()
	if err != nil {
		parseLog("[sniff] chromium missing err=%v", err)
		return "", nil, err
	}

	sniffSem <- struct{}{}
	defer func() { <-sniffSem }()

	tabCtx, cancelTab := chromedp.NewContext(allocCtx)
	defer cancelTab()
	ctx, cancelTimeout := context.WithTimeout(tabCtx, timeout)
	defer cancelTimeout()

	found := make(chan sniffHit, 1)
	var once sync.Once
	emit := func(u string, reqHdr map[string]string) {
		if u == "" || !videoOK(u) {
			return
		}
		if IsAdURL(u) {
			return
		}
		// 非 detect 时，当前页自身 URL 不算嗅探结果
		if !detect && sameURL(u, pageURL) {
			return
		}
		once.Do(func() {
			found <- sniffHit{url: u, headers: reqHdr}
		})
	}

	var followMu sync.Mutex
	followed := map[string]bool{}
	chromedp.ListenTarget(ctx, func(ev any) {
		switch e := ev.(type) {
		case *fetch.EventRequestPaused:
			// 对齐 TV shouldInterceptRequest：广告 host 阻断请求（空响应等效）。
			reqID := e.RequestID
			u := ""
			if e.Request != nil {
				u = e.Request.URL
			}
			go func() {
				if u != "" && IsAdURL(u) {
					_ = fetch.FailRequest(reqID, network.ErrorReasonBlockedByClient).Do(ctx)
					return
				}
				_ = fetch.ContinueRequest(reqID).Do(ctx)
			}()
		case *network.EventRequestWillBeSent:
			if e.Request == nil {
				return
			}
			u := e.Request.URL
			reqHdr := headerFromNetwork(e.Request.Headers)
			if IsAdURL(u) {
				return
			}
			// 嵌套嗅探：TV player.*http；跨站 Document/iframe 通用跟进（上限 maxNestedPlayers）。
			if detect && depth < 1 && shouldFollowNestedPlayer(u, pageURL, e.Type) {
				followMu.Lock()
				dup := followed[u]
				n := len(followed)
				if !dup && n < maxNestedPlayers {
					followed[u] = true
				} else if !dup {
					dup = true // 超额不再跟进
				}
				followMu.Unlock()
				if !dup {
					parseLog("[sniff] follow nested depth=%d type=%s url=%s", depth, e.Type, parsePreview(u, 160))
					go func(target string, h map[string]string) {
						remain := time.Until(deadlineOf(ctx))
						if remain < 3*time.Second {
							remain = 3 * time.Second
						}
						nested, nh, err := browserSniff(target, mergeHeaders(headers, h), click, rules, remain, false, isVideo, depth+1)
						if err == nil && nested != "" {
							emit(nested, nh)
						}
					}(u, reqHdr)
				}
				return
			}
			emit(u, reqHdr)
		case *network.EventResponseReceived:
			if e.Response == nil {
				return
			}
			// 部分源 URL 无扩展名，靠 MIME 识别；仍过 videoOK / ads（与请求路径一致）。
			mime := strings.ToLower(e.Response.MimeType)
			u := e.Response.URL
			if strings.Contains(mime, "mpegurl") ||
				strings.Contains(mime, "m3u8") ||
				strings.Contains(mime, "application/vnd.apple.mpegurl") ||
				strings.HasPrefix(mime, "video/") ||
				strings.HasPrefix(mime, "audio/") {
				emit(u, headerFromNetwork(e.Response.Headers))
				return
			}
			emit(u, headerFromNetwork(e.Response.Headers))
		}
	})

	actions := []chromedp.Action{
		network.Enable(),
		fetch.Enable(),
		chromedp.ActionFunc(func(ctx context.Context) error {
			// 对齐 TV CustomWebView：结果头里的 UA 必须进 WebView，否则防盗链/移动源不吐流。
			if ua := headerValue(headers, "User-Agent"); ua != "" {
				if err := emulation.SetUserAgentOverride(ua).Do(ctx); err != nil {
					return err
				}
			}
			if len(headers) == 0 {
				return nil
			}
			extra := network.Headers{}
			for k, v := range headers {
				if strings.EqualFold(k, "User-Agent") || strings.EqualFold(k, "Cookie") {
					continue
				}
				extra[k] = v
			}
			if len(extra) == 0 {
				return nil
			}
			return network.SetExtraHTTPHeaders(extra).Do(ctx)
		}),
		chromedp.ActionFunc(func(ctx context.Context) error {
			cookie := headerValue(headers, "Cookie")
			if cookie == "" {
				return nil
			}
			return applyCookies(ctx, pageURL, cookie)
		}),
		chromedp.Navigate(pageURL),
		chromedp.Sleep(600 * time.Millisecond),
		chromedp.ActionFunc(func(ctx context.Context) error {
			// 去掉 webdriver 标记（部分云解析会检测）。
			_ = chromedp.Evaluate(`Object.defineProperty(navigator,'webdriver',{get:()=>undefined})`, nil).Do(ctx)
			return nil
		}),
	}
	scripts := collectScripts(pageURL, click, rules)
	for _, js := range scripts {
		js := js
		actions = append(actions,
			chromedp.ActionFunc(func(ctx context.Context) error {
				if strings.TrimSpace(js) == "" {
					return nil
				}
				return chromedp.Evaluate(js, nil).Do(ctx)
			}),
			chromedp.Sleep(300*time.Millisecond),
		)
	}
	// 主动收集 iframe.src（MacPlayer 延迟写入），跟进嵌套页；同时轮询 DOM 媒体。
	actions = append(actions, chromedp.ActionFunc(func(ctx context.Context) error {
		deadline := deadlineOf(ctx)
		ticker := time.NewTicker(700 * time.Millisecond)
		defer ticker.Stop()
		for {
			if detect && depth < 1 {
				for _, iframe := range collectIFrameURLs(ctx) {
					if IsAdURL(iframe) || !shouldFollowNestedPlayer(iframe, pageURL, network.ResourceTypeDocument) {
						continue
					}
					followMu.Lock()
					dup := followed[iframe]
					n := len(followed)
					if !dup && n < maxNestedPlayers {
						followed[iframe] = true
					} else {
						dup = true
					}
					followMu.Unlock()
					if dup {
						continue
					}
					parseLog("[sniff] follow iframe depth=%d url=%s", depth, parsePreview(iframe, 160))
					go func(target string) {
						remain := time.Until(deadline)
						if remain < 3*time.Second {
							remain = 3 * time.Second
						}
						nested, nh, err := browserSniff(target, headers, click, rules, remain, false, isVideo, depth+1)
						if err == nil && nested != "" {
							emit(nested, nh)
						}
					}(iframe)
				}
			}
			if u, h := probeDOMMedia(ctx, videoOK); u != "" {
				emit(u, h)
			}
			select {
			case <-ctx.Done():
				return ctx.Err()
			case <-ticker.C:
				if time.Now().After(deadline.Add(-400 * time.Millisecond)) {
					return nil
				}
			}
		}
	}))

	runErr := make(chan error, 1)
	go func() {
		runErr <- chromedp.Run(ctx, actions...)
	}()

	select {
	case hit := <-found:
		cancelTimeout()
		parseLog("[sniff] chromium ok depth=%d out=%s cost=%s", depth, parsePreview(hit.url, 160), time.Since(start).Truncate(time.Millisecond))
		return hit.url, hit.headers, nil
	case err := <-runErr:
		if u, h := fallbackDOM(ctx, rules, isVideo); u != "" {
			parseLog("[sniff] chromium fallbackDOM ok depth=%d out=%s cost=%s", depth, parsePreview(u, 160), time.Since(start).Truncate(time.Millisecond))
			return u, h, nil
		}
		if err != nil && ctx.Err() == nil {
			parseLog("[sniff] chromium fail depth=%d err=%v cost=%s", depth, err, time.Since(start).Truncate(time.Millisecond))
			return "", nil, fmt.Errorf("网页嗅探失败: %w", err)
		}
		parseLog("[sniff] chromium miss depth=%d cost=%s", depth, time.Since(start).Truncate(time.Millisecond))
		return "", nil, fmt.Errorf("未嗅探到媒体地址")
	case <-ctx.Done():
		if u, h := fallbackDOM(ctx, rules, isVideo); u != "" {
			parseLog("[sniff] chromium timeout+DOM ok depth=%d out=%s cost=%s", depth, parsePreview(u, 160), time.Since(start).Truncate(time.Millisecond))
			return u, h, nil
		}
		if ctx.Err() == context.DeadlineExceeded {
			parseLog("[sniff] chromium timeout depth=%d after=%s", depth, timeout)
			return "", nil, fmt.Errorf("网页嗅探超时（Chromium 未在 %s 内找到媒体地址）", timeout)
		}
		parseLog("[sniff] chromium canceled depth=%d err=%v", depth, ctx.Err())
		return "", nil, ctx.Err()
	}
}

func androidBrowserSniff(pageURL string, headers map[string]string, click string, rules []model.Rule, ads []string, timeout time.Duration, detect bool, isVideo func(string) bool) (string, map[string]string, error) {
	const base = "http://127.0.0.1:9979/sniff"
	if len(rules) == 0 {
		rules = GetRules()
	}
	if len(ads) == 0 {
		ads = GetAds()
	}
	reqBody := map[string]interface{}{
		"url":       pageURL,
		"headers":   headers,
		"timeoutMs": int(timeout / time.Millisecond),
		"click":     click,
		"rules":     rules,
		"ads":       ads,
		"detect":    detect,
	}
	b, err := json.Marshal(reqBody)
	if err != nil {
		return "", nil, err
	}
	req, err := http.NewRequest(http.MethodPost, base, bytes.NewReader(b))
	if err != nil {
		return "", nil, err
	}
	req.Header.Set("Content-Type", "application/json; charset=utf-8")

	client := &http.Client{Timeout: timeout + 5*time.Second}
	resp, err := client.Do(req)
	if err != nil {
		return "", nil, err
	}
	defer resp.Body.Close()

	respBody, _ := io.ReadAll(io.LimitReader(resp.Body, 2<<20))
	if resp.StatusCode >= 400 {
		return "", nil, fmt.Errorf("android sniff failed: http=%d %s", resp.StatusCode, strings.TrimSpace(string(respBody)))
	}

	var out struct {
		URL     string            `json:"url"`
		Headers map[string]string `json:"headers"`
		Error   string            `json:"error"`
	}
	if err := json.Unmarshal(respBody, &out); err != nil {
		return "", nil, err
	}
	if out.Error != "" {
		return "", nil, fmt.Errorf("android sniff error: %s", out.Error)
	}
	u := strings.TrimSpace(out.URL)
	if u == "" || (isVideo != nil && !isVideo(u)) {
		return "", nil, fmt.Errorf("未嗅探到媒体地址")
	}
	var hdr map[string]string
	if len(out.Headers) > 0 {
		hdr = cloneHeaderMap(out.Headers)
	}
	// Android sniff 没有请求头细节时 hdr 为空；上层会回退到原 headers。
	return u, hdr, nil
}

func fallbackDOM(ctx context.Context, rules []model.Rule, isVideo func(string) bool) (string, map[string]string) {
	videoOK := func(u string) bool {
		if isVideo != nil {
			return isVideo(u)
		}
		return IsVideoFormatRules(u, rules)
	}
	return probeDOMMedia(ctx, videoOK)
}

func probeDOMMedia(ctx context.Context, videoOK func(string) bool) (string, map[string]string) {
	var html string
	if err := chromedp.OuterHTML("html", &html).Do(ctx); err == nil {
		if u := ExtractMediaURL(html); videoOK(u) {
			return u, nil
		}
	}
	var hrefs string
	_ = chromedp.Evaluate(
		`(() => {
			const out = [];
			document.querySelectorAll('video,source').forEach(e => {
				const s = e.currentSrc || e.src || e.getAttribute('src') || '';
				if (s) out.push(s);
			});
			document.querySelectorAll('iframe').forEach(f => {
				try {
					const d = f.contentDocument;
					if (!d) return;
					d.querySelectorAll('video,source').forEach(e => {
						const s = e.currentSrc || e.src || e.getAttribute('src') || '';
						if (s) out.push(s);
					});
				} catch (e) {}
			});
			return out.filter(Boolean).join('\n');
		})()`,
		&hrefs,
	).Do(ctx)
	for _, line := range strings.Split(hrefs, "\n") {
		line = strings.TrimSpace(line)
		if videoOK(line) {
			return line, nil
		}
	}
	return "", nil
}

func collectIFrameURLs(ctx context.Context) []string {
	var raw string
	_ = chromedp.Evaluate(
		`Array.from(document.querySelectorAll('iframe'))
			.map(f => f.src || f.getAttribute('src') || '')
			.filter(s => /^https?:\/\//i.test(s))
			.join('\n')`,
		&raw,
	).Do(ctx)
	var out []string
	seen := map[string]bool{}
	for _, line := range strings.Split(raw, "\n") {
		line = strings.TrimSpace(line)
		if line == "" || seen[line] {
			continue
		}
		seen[line] = true
		out = append(out, line)
	}
	return out
}

// shouldFollowNestedPlayer 决定是否再开一层嗅探。
// 对齐 TV：PLAYER 正则；并通用跟进跨站 Document/iframe（MacPlayer 等不保证 URL 含 "player"）。
func shouldFollowNestedPlayer(u, pageURL string, resType network.ResourceType) bool {
	u = strings.TrimSpace(u)
	if u == "" || sameURL(u, pageURL) {
		return false
	}
	if !strings.HasPrefix(strings.ToLower(u), "http://") && !strings.HasPrefix(strings.ToLower(u), "https://") {
		return false
	}
	if playerURLRe.MatchString(u) {
		return true
	}
	switch resType {
	case network.ResourceTypeDocument, network.ResourceTypeOther, "":
		ph, uh := hostOf(pageURL), hostOf(u)
		return ph != "" && uh != "" && !strings.EqualFold(ph, uh)
	default:
		return false
	}
}

func collectScripts(pageURL, click string, rules []model.Rule) []string {
	var out []string
	if click != "" {
		out = append(out, click)
	}
	// 对齐 TV Sniffer.getRule：page host + ?url= 内层 host
	hosts := sniffHosts(pageURL)
	for _, rule := range rules {
		if !hostsMatched(hosts, rule.Hosts) {
			continue
		}
		for _, s := range rule.Script {
			s = strings.TrimSpace(s)
			if s == "" {
				continue
			}
			dup := false
			for _, e := range out {
				if e == s {
					dup = true
					break
				}
			}
			if !dup {
				out = append(out, s)
			}
		}
	}
	return out
}

func applyCookies(ctx context.Context, pageURL, cookieHeader string) error {
	u, err := url.Parse(pageURL)
	if err != nil || u.Host == "" {
		return nil
	}
	parts := strings.Split(cookieHeader, ";")
	for _, p := range parts {
		p = strings.TrimSpace(p)
		if p == "" {
			continue
		}
		name, val, ok := strings.Cut(p, "=")
		if !ok {
			continue
		}
		name = strings.TrimSpace(name)
		val = strings.TrimSpace(val)
		if name == "" {
			continue
		}
		expr := network.SetCookie(name, val).
			WithURL(pageURL).
			WithDomain(u.Hostname()).
			WithPath("/")
		if err := expr.Do(ctx); err != nil {
			return err
		}
	}
	return nil
}

func headerValue(h map[string]string, key string) string {
	if h == nil {
		return ""
	}
	for k, v := range h {
		if strings.EqualFold(k, key) {
			return v
		}
	}
	return ""
}

func headerFromNetwork(h network.Headers) map[string]string {
	if h == nil {
		return nil
	}
	out := make(map[string]string, len(h))
	for k, v := range h {
		switch t := v.(type) {
		case string:
			out[k] = t
		default:
			out[k] = fmt.Sprint(t)
		}
	}
	return out
}

func cloneHeaderMap(h map[string]string) map[string]string {
	if h == nil {
		return nil
	}
	out := make(map[string]string, len(h))
	for k, v := range h {
		out[k] = v
	}
	return out
}

func sameURL(a, b string) bool {
	return strings.TrimSpace(a) == strings.TrimSpace(b)
}

func deadlineOf(ctx context.Context) time.Time {
	d, ok := ctx.Deadline()
	if !ok {
		return time.Now().Add(defaultParseWebTimeout)
	}
	return d
}

func hostOf(raw string) string {
	u, err := url.Parse(raw)
	if err != nil {
		return ""
	}
	return u.Hostname()
}

// sniffHosts 对齐 TV Sniffer.getRule：主 host + ?url= 内层 host，逗号拼接供 ContainOrMatch。
func sniffHosts(raw string) string {
	u, err := url.Parse(raw)
	if err != nil || u.Hostname() == "" {
		return ""
	}
	parts := []string{u.Hostname()}
	if q := u.Query().Get("url"); q != "" {
		if qu, err := url.Parse(q); err == nil && qu.Hostname() != "" {
			parts = append(parts, qu.Hostname())
		}
	}
	return strings.Join(parts, ",")
}

func hostMatched(host string, hosts []string) bool {
	return hostsMatched(host, hosts)
}

func hostsMatched(hostsCSV string, patterns []string) bool {
	if hostsCSV == "" || len(patterns) == 0 {
		return false
	}
	for _, h := range patterns {
		h = strings.TrimSpace(h)
		if h == "" {
			continue
		}
		// 对齐 TV Util.containOrMatch(hosts, host)
		if util.ContainOrMatch(hostsCSV, h) {
			return true
		}
	}
	return false
}
