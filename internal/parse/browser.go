package parse

import (
	"context"
	"fmt"
	"net/url"
	"strings"
	"sync"
	"time"

	"github.com/chromedp/cdproto/network"
	"github.com/chromedp/chromedp"

	"github.com/bobo/KOTV/internal/model"
	appruntime "github.com/bobo/KOTV/internal/runtime"
)

// 网页嗅探总超时（秒级）；冷启动 Chromium 也算在这段时间内。
const defaultParseWebTimeout = 15 * time.Second

// BrowserSniff 用无头 Chromium 拦截网络请求嗅探媒体地址。
func BrowserSniff(pageURL string, headers map[string]string, timeout time.Duration) (string, error) {
	return BrowserSniffWithClick(pageURL, headers, "", nil, timeout)
}

// BrowserSniffWithClick 嗅探媒体地址，可选执行 click / 规则脚本，并应用请求头。
func BrowserSniffWithClick(pageURL string, headers map[string]string, click string, rules []model.Rule, timeout time.Duration) (string, error) {
	u, _, err := browserSniff(pageURL, headers, click, rules, timeout, true, nil)
	return u, err
}

type sniffHit struct {
	url     string
	headers map[string]string
}

func browserSniff(pageURL string, headers map[string]string, click string, rules []model.Rule, timeout time.Duration, detect bool, isVideo func(string) bool) (string, map[string]string, error) {
	pageURL = strings.TrimSpace(pageURL)
	if pageURL == "" {
		return "", nil, nil
	}
	videoOK := func(u string) bool {
		if isVideo != nil {
			return isVideo(u)
		}
		return IsVideoFormatRules(u, rules)
	}
	if videoOK(pageURL) {
		return pageURL, cloneHeaderMap(headers), nil
	}
	if timeout <= 0 {
		timeout = defaultParseWebTimeout // 与常见网页解析超时一致：15s
	}

	opts := append(chromedp.DefaultExecAllocatorOptions[:],
		chromedp.Flag("headless", true),
		chromedp.Flag("disable-gpu", true),
		chromedp.Flag("no-sandbox", true),
		chromedp.Flag("autoplay-policy", "no-user-gesture-required"),
	)
	if ua := headerValue(headers, "User-Agent"); ua != "" {
		opts = append(opts, chromedp.UserAgent(ua))
	}
	if chrome := appruntime.Chromium(); chrome != "" {
		opts = append(opts, chromedp.ExecPath(chrome))
	}

	allocCtx, cancelAlloc := chromedp.NewExecAllocator(context.Background(), opts...)
	defer cancelAlloc()

	ctx, cancelCtx := chromedp.NewContext(allocCtx)
	defer cancelCtx()
	ctx, cancelTimeout := context.WithTimeout(ctx, timeout)
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
		case *network.EventRequestWillBeSent:
			if e.Request == nil {
				return
			}
			u := e.Request.URL
			reqHdr := headerFromNetwork(e.Request.Headers)
			if IsAdURL(u) {
				return
			}
			if detect && playerURLRe.MatchString(u) {
				followMu.Lock()
				dup := followed[u]
				if !dup {
					followed[u] = true
				}
				followMu.Unlock()
				if !dup {
					go func(target string, h map[string]string) {
						remain := time.Until(deadlineOf(ctx))
						if remain < 2*time.Second {
							remain = 2 * time.Second
						}
						nested, nh, err := browserSniff(target, mergeHeaders(headers, h), click, rules, remain, false, isVideo)
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
			// 部分源 URL 无扩展名，靠 MIME 识别
			mime := strings.ToLower(e.Response.MimeType)
			u := e.Response.URL
			if strings.Contains(mime, "mpegurl") ||
				strings.Contains(mime, "m3u8") ||
				strings.Contains(mime, "application/vnd.apple.mpegurl") ||
				strings.HasPrefix(mime, "video/") ||
				strings.HasPrefix(mime, "audio/") {
				if !IsAdURL(u) {
					once.Do(func() {
						found <- sniffHit{url: u, headers: headerFromNetwork(e.Response.Headers)}
					})
				}
				return
			}
			emit(u, headerFromNetwork(e.Response.Headers))
		}
	})

	actions := []chromedp.Action{
		network.Enable(),
		chromedp.ActionFunc(func(ctx context.Context) error {
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
		chromedp.Sleep(800 * time.Millisecond),
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
			chromedp.Sleep(400*time.Millisecond),
		)
	}
	// 导航 + 脚本后，在剩余超时内持续监听网络（命中即提前返回）。
	// 2s 只是旧版里导航后的短 sleep，不是总超时；总超时默认 15s。
	listenFor := time.Until(deadlineOf(ctx)) - time.Second
	if listenFor < 5*time.Second {
		listenFor = 5 * time.Second
	}
	actions = append(actions, chromedp.Sleep(listenFor))

	runErr := make(chan error, 1)
	go func() {
		runErr <- chromedp.Run(ctx, actions...)
	}()

	select {
	case hit := <-found:
		cancelTimeout()
		return hit.url, hit.headers, nil
	case err := <-runErr:
		if u, h := fallbackDOM(ctx, rules, isVideo); u != "" {
			return u, h, nil
		}
		if err != nil && ctx.Err() == nil {
			return "", nil, err
		}
		return "", nil, fmt.Errorf("未嗅探到媒体地址")
	case <-ctx.Done():
		if u, h := fallbackDOM(ctx, rules, isVideo); u != "" {
			return u, h, nil
		}
		return "", nil, ctx.Err()
	}
}

func fallbackDOM(ctx context.Context, rules []model.Rule, isVideo func(string) bool) (string, map[string]string) {
	videoOK := func(u string) bool {
		if isVideo != nil {
			return isVideo(u)
		}
		return IsVideoFormatRules(u, rules)
	}
	var html string
	if err := chromedp.Run(ctx, chromedp.OuterHTML("html", &html)); err == nil {
		if u := ExtractMediaURL(html); videoOK(u) {
			return u, nil
		}
	}
	var hrefs string
	_ = chromedp.Run(ctx, chromedp.Evaluate(
		`Array.from(document.querySelectorAll('video,source')).map(e=>e.src||e.currentSrc).filter(Boolean).join('\n')`,
		&hrefs,
	))
	for _, line := range strings.Split(hrefs, "\n") {
		line = strings.TrimSpace(line)
		if videoOK(line) {
			return line, nil
		}
	}
	return "", nil
}

func collectScripts(pageURL, click string, rules []model.Rule) []string {
	var out []string
	if click != "" {
		out = append(out, click)
	}
	host := hostOf(pageURL)
	for _, rule := range rules {
		if !hostMatched(host, rule.Hosts) {
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

func hostMatched(host string, hosts []string) bool {
	if host == "" || len(hosts) == 0 {
		return false
	}
	for _, h := range hosts {
		h = strings.TrimSpace(h)
		if h == "" {
			continue
		}
		if strings.EqualFold(host, h) || strings.Contains(strings.ToLower(host), strings.ToLower(h)) {
			return true
		}
	}
	return false
}
