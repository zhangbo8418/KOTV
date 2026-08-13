package parse

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"regexp"
	"runtime"
	"strings"
	"sync"
	"time"

	"github.com/chromedp/cdproto/cdp"
	"github.com/chromedp/cdproto/emulation"
	"github.com/chromedp/cdproto/network"
	"github.com/chromedp/cdproto/page"
	"github.com/chromedp/chromedp"

	"github.com/bobo/KOTV/internal/hostclient"
	"github.com/bobo/KOTV/internal/model"
	appruntime "github.com/bobo/KOTV/internal/runtime"
	"github.com/bobo/KOTV/internal/util"
)

// 网页嗅探总超时；含嵌套云播页冷启动 + XHR，15s 在 Win7/慢机上不够。
const defaultParseWebTimeout = 30 * time.Second

// 嵌套嗅探至少留这么久，避免壳页耗掉大半时间后云播页秒超时。
const nestedSniffMinTimeout = 18 * time.Second

// CustomWebView.MAX_URLS：嵌套 player 页最多跟进 5 个竞速。
const maxNestedPlayers = 5

// 与 drpy2 顶层常量一致；嗅探展开 headers 魔串 MOBILE_UA/PC_UA/UA/UC_UA/IOS_UA。
const (
	sniffUAMobile = "Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.6613.88 Mobile Safari/537.36"
	sniffUAPC     = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/153.0.0.0 Safari/537.36"
	sniffUABare   = "Mozilla/5.0"
	sniffUAUC     = "Mozilla/5.0 (Linux; U; Android 9; zh-CN; MI 9 Build/PKQ1.181121.001) AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/57.0.2987.108 UCBrowser/12.5.5.1035 Mobile Safari/537.36"
	sniffUAIOS    = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1"
)

// 桌面共享一个 Chromium 进程；最多 2 个并发 tab，避免超级解析打出几十个 chrome。
// 按 userID 登记进行中的 sniff cancel，供 KillUserRuntime / 心跳回收。
var (
	sharedAllocOnce   sync.Once
	sharedAllocCtx    context.Context
	sharedAllocCancel context.CancelFunc
	sharedAllocErr    error
	sniffSem          = make(chan struct{}, 2)

	userSniffMu sync.Mutex
	userSniffs  = map[string][]context.CancelFunc{} // userID -> cancels
)

// trackUserSniff 登记一次嗅探；返回 unregister。
func trackUserSniff(userID string, cancel context.CancelFunc) func() {
	userID = strings.TrimSpace(userID)
	if userID == "" || cancel == nil {
		return func() {}
	}
	userSniffMu.Lock()
	userSniffs[userID] = append(userSniffs[userID], cancel)
	idx := len(userSniffs[userID]) - 1
	userSniffMu.Unlock()
	return func() {
		userSniffMu.Lock()
		defer userSniffMu.Unlock()
		list := userSniffs[userID]
		if idx < 0 || idx >= len(list) {
			return
		}
		// 置空保留下标，避免并发 unregister 乱序
		list[idx] = nil
		allNil := true
		for _, c := range list {
			if c != nil {
				allNil = false
				break
			}
		}
		if allNil {
			delete(userSniffs, userID)
		} else {
			userSniffs[userID] = list
		}
	}
}

// CancelUserSniffs 取消该用户全部进行中的 Chromium 嗅探（心跳/登出时调用）。
func CancelUserSniffs(userID string) {
	userID = strings.TrimSpace(userID)
	if userID == "" {
		return
	}
	userSniffMu.Lock()
	list := userSniffs[userID]
	delete(userSniffs, userID)
	userSniffMu.Unlock()
	for _, cancel := range list {
		if cancel != nil {
			cancel()
		}
	}
}

func ensureSharedChromium() (context.Context, error) {
	sharedAllocOnce.Do(func() {
		chrome := appruntime.Chromium()
		if chrome == "" {
			sharedAllocErr = fmt.Errorf("未找到 Chromium：网页嗅探不可用（请检查 runtime/chromium）")
			return
		}
		opts := append(chromedp.DefaultExecAllocatorOptions[:],
			// headless-shell 对 headless=new 兼容差，易卡住无收尾日志。
			chromedp.Flag("headless", "old"),
			chromedp.Flag("disable-gpu", true),
			chromedp.Flag("no-sandbox", true),
			chromedp.Flag("disable-dev-shm-usage", true),
			chromedp.Flag("mute-audio", true),
			chromedp.Flag("hide-scrollbars", true),
			chromedp.Flag("autoplay-policy", "no-user-gesture-required"),
			chromedp.Flag("disable-blink-features", "AutomationControlled"),
			chromedp.Flag("disable-infobars", true),
			// 让跨站 iframe 网络事件落到同一 target，父页才能直接嗅到媒体。
			chromedp.Flag("disable-features", "TranslateUI,BlinkGenPropertyTrees,IsolateOrigins,site-per-process"),
			chromedp.ExecPath(chrome),
		)
		if runtime.GOOS == "windows" {
			opts = append(opts,
				chromedp.Flag("disable-software-rasterizer", true),
				chromedp.Flag("disable-extensions", true),
				chromedp.Flag("disable-background-networking", true),
				chromedp.Flag("disable-background-timer-throttling", true),
				chromedp.Flag("disable-renderer-backgrounding", true),
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

func browserSniff(pageURL string, headers map[string]string, click string, rules []model.Rule, timeout time.Duration, detect bool, isVideo func(string) bool, depth int) (outURL string, outHdr map[string]string, err error) {
	pageURL = strings.TrimSpace(pageURL)
	if pageURL == "" {
		return "", nil, nil
	}
	start := time.Now()
	parseLog("[sniff] start depth=%d detect=%v timeout=%s click=%q url=%s", depth, detect, timeout, click, parsePreview(pageURL, 160))
	defer func() {
		cost := time.Since(start).Truncate(time.Millisecond)
		if outURL != "" {
			parseLog("[sniff] end depth=%d ok out=%s cost=%s", depth, parsePreview(outURL, 160), cost)
		} else if err != nil {
			parseLog("[sniff] end depth=%d err=%v cost=%s", depth, err, cost)
		} else {
			parseLog("[sniff] end depth=%d empty cost=%s", depth, cost)
		}
	}()
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
		timeout = defaultParseWebTimeout
	}

	// Android：不用 Chromium / chromedp；改走本地 Native Service(WebView)嗅探。
	if runtime.GOOS == "android" {
		u, h, e := androidBrowserSniff(pageURL, headers, click, rules, GetAds(), timeout, detect, videoOK)
		return u, h, e
	}

	allocCtx, e := ensureSharedChromium()
	if e != nil {
		parseLog("[sniff] chromium missing err=%v", e)
		return "", nil, e
	}

	// 仅顶层占信号量；嵌套跟进不再抢，避免父子互相堵死。
	if depth == 0 {
		select {
		case sniffSem <- struct{}{}:
			defer func() { <-sniffSem }()
		case <-time.After(timeout):
			return "", nil, fmt.Errorf("网页嗅探排队超时")
		}
	}

	tabCtx, cancelTab := chromedp.NewContext(allocCtx)
	defer cancelTab()
	ctx, cancelTimeout := context.WithTimeout(tabCtx, timeout)
	defer cancelTimeout()
	untrack := trackUserSniff(hostclient.RuntimeUserID(), func() {
		cancelTab()
		cancelTimeout()
	})
	defer untrack()
	// chromedp 偶发不响应 ctx 取消：再加硬超时强杀 tab。
	hardTimer := time.AfterFunc(timeout+3*time.Second, func() {
		parseLog("[sniff] hard-cancel depth=%d after=%s", depth, timeout+3*time.Second)
		cancelTab()
		cancelTimeout()
	})
	defer hardTimer.Stop()

	found := make(chan sniffHit, 1)
	var once sync.Once
	emit := func(u string, reqHdr map[string]string) {
		if u == "" || !videoOK(u) {
			return
		}
		if IsAdURL(u) {
			return
		}
		if !detect && sameURL(u, pageURL) {
			return
		}
		once.Do(func() {
			found <- sniffHit{url: u, headers: reqHdr}
		})
	}

	var followMu sync.Mutex
	followed := map[string]bool{}
	tryFollow := func(target string, h map[string]string, why string) {
		if detect && depth < 1 && shouldFollowNestedPlayer(target, pageURL, network.ResourceTypeDocument) {
			key := nestedFollowKey(target)
			followMu.Lock()
			dup := followed[key]
			n := len(followed)
			if !dup && n < maxNestedPlayers {
				followed[key] = true
			} else {
				dup = true
			}
			followMu.Unlock()
			if dup {
				return
			}
			parseLog("[sniff] follow %s depth=%d key=%s url=%s", why, depth, key, parsePreview(target, 160))
			go func(target string, h map[string]string) {
				remain := time.Until(deadlineOf(ctx))
				if remain < nestedSniffMinTimeout {
					remain = nestedSniffMinTimeout
				}
				// 嵌套页自带超时；父页须有足够总时长等它（见 defaultParseWebTimeout）。
				nested, nh, nerr := browserSniff(target, mergeHeaders(headers, h), click, rules, remain, false, isVideo, depth+1)
				if nerr == nil && nested != "" {
					emit(nested, nh)
				} else if nerr != nil {
					parseLog("[sniff] follow fail depth=%d err=%v url=%s", depth+1, nerr, parsePreview(target, 120))
				}
			}(target, h)
		}
	}

	// XHR/Fetch 响应体候选（部分接口以 text/html 返回 JSON 播放地址）。
	type bodyCand struct {
		url  string
		mime string
		typ  network.ResourceType
	}
	var bodyMu sync.Mutex
	bodyPending := map[network.RequestID]bodyCand{}
	tryEmitFromBody := func(reqID network.RequestID) {
		bodyMu.Lock()
		cand, ok := bodyPending[reqID]
		if ok {
			delete(bodyPending, reqID)
		}
		bodyMu.Unlock()
		if !ok {
			return
		}
		c := chromedp.FromContext(ctx)
		if c == nil || c.Target == nil {
			return
		}
		body, err := network.GetResponseBody(reqID).Do(cdp.WithExecutor(context.Background(), c.Target))
		if err != nil || len(body) == 0 || len(body) > 512*1024 {
			return
		}
		text := string(body)
		if play, hdr, note := sniffPlayAPIResult(text); note != "" {
			parseLog("[sniff] play-api depth=%d %s from=%s", depth, note, parsePreview(cand.url, 80))
		} else if play != "" {
			parseLog("[sniff] xhr-json depth=%d from=%s out=%s", depth, parsePreview(cand.url, 80), parsePreview(play, 120))
			emit(play, sanitizePlayHeaders(hdr))
			return
		}
		if u := ExtractMediaURL(text); u != "" {
			emit(u, nil)
		}
	}

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
			// 已是媒体直链时直接收，勿当嵌套页跟进。
			if videoOK(u) {
				emit(u, reqHdr)
				return
			}
			if detect && depth < 1 && shouldFollowNestedPlayer(u, pageURL, e.Type) {
				tryFollow(u, reqHdr, "net")
				return
			}
			emit(u, reqHdr)
		case *network.EventResponseReceived:
			if e.Response == nil {
				return
			}
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
			if shouldParseSniffBody(u, mime, e.Type) {
				bodyMu.Lock()
				bodyPending[e.RequestID] = bodyCand{url: u, mime: mime, typ: e.Type}
				bodyMu.Unlock()
			}
			emit(u, headerFromNetwork(e.Response.Headers))
		case *network.EventLoadingFinished:
			reqID := e.RequestID
			go tryEmitFromBody(reqID)
		}
	})

	parseLog("[sniff] chromium run depth=%d", depth)
	actions := []chromedp.Action{
		network.Enable(),
		chromedp.ActionFunc(func(ctx context.Context) error {
			prof := resolveSniffProfile(headers)
			parseLog("[sniff] client depth=%d mobile=%v platform=%s ua=%s", depth, prof.mobile, prof.platform, parsePreview(prof.ua, 80))
			uaOverride := emulation.SetUserAgentOverride(prof.ua).
				WithPlatform(prof.platform).
				WithUserAgentMetadata(sniffUAMetadata(prof))
			if err := uaOverride.Do(ctx); err != nil {
				return err
			}
			_, err := page.AddScriptToEvaluateOnNewDocument(sniffStealthJS(prof)).Do(ctx)
			if err != nil {
				return err
			}
			if len(headers) == 0 {
				return nil
			}
			extra := network.Headers{}
			for k, v := range headers {
				// Referer 只用于 Navigate.WithReferrer；写进 ExtraHeaders 会污染云播跳转/XHR。
				if strings.EqualFold(k, "User-Agent") || strings.EqualFold(k, "Cookie") || strings.EqualFold(k, "Referer") {
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
		// 勿用 chromedp.Navigate：它会等 load；广告站常永不 load，15s 超时前轮询/跟 iframe 跑不动。
		chromedp.ActionFunc(func(ctx context.Context) error {
			nav := page.Navigate(pageURL)
			if ref := headerValue(headers, "Referer"); ref != "" {
				nav = nav.WithReferrer(ref)
			}
			_, _, _, _, err := nav.Do(ctx)
			return err
		}),
		chromedp.Sleep(1200 * time.Millisecond),
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
	// 轮询 iframe.src + DOM 媒体；总时长由 ctx 超时约束。
	actions = append(actions, chromedp.ActionFunc(func(ctx context.Context) error {
		deadline := deadlineOf(ctx)
		ticker := time.NewTicker(800 * time.Millisecond)
		defer ticker.Stop()
		for {
			if detect && depth < 1 {
				for _, iframe := range collectIFrameURLs(ctx) {
					if IsAdURL(iframe) {
						continue
					}
					tryFollow(iframe, nil, "iframe")
				}
			}
			if u, h := probeDOMMedia(ctx, videoOK); u != "" {
				emit(u, h)
			}
			select {
			case <-ctx.Done():
				return ctx.Err()
			case <-ticker.C:
				if time.Now().After(deadline.Add(-500 * time.Millisecond)) {
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
		return hit.url, hit.headers, nil
	case runE := <-runErr:
		if hit, ok := waitSniffHit(found, 2*time.Second); ok {
			cancelTimeout()
			return hit.url, hit.headers, nil
		}
		select {
		case <-tabCtx.Done():
		default:
			if u, h := fallbackDOM(tabCtx, rules, isVideo); u != "" {
				return u, h, nil
			}
			logSniffPageDiag(tabCtx, depth)
		}
		if runE != nil && ctx.Err() == nil {
			return "", nil, fmt.Errorf("网页嗅探失败: %w", runE)
		}
		return "", nil, fmt.Errorf("未嗅探到媒体地址")
	case <-ctx.Done():
		// 嵌套云播页 goroutine 可能略晚于父 ctx；再等一小会儿。
		if hit, ok := waitSniffHit(found, 5*time.Second); ok {
			cancelTimeout()
			return hit.url, hit.headers, nil
		}
		select {
		case <-tabCtx.Done():
		default:
			if u, h := fallbackDOM(tabCtx, rules, isVideo); u != "" {
				return u, h, nil
			}
			logSniffPageDiag(tabCtx, depth)
		}
		if ctx.Err() == context.DeadlineExceeded {
			return "", nil, fmt.Errorf("网页嗅探超时（Chromium 未在 %s 内找到媒体地址）", timeout)
		}
		return "", nil, ctx.Err()
	case <-time.After(timeout + 4*time.Second):
		if hit, ok := waitSniffHit(found, 2*time.Second); ok {
			cancelTimeout()
			return hit.url, hit.headers, nil
		}
		cancelTab()
		return "", nil, fmt.Errorf("网页嗅探硬超时（Chromium 无响应）")
	}
}

// waitSniffHit 在 grace 内等非阻塞地收嵌套嗅探结果。
func waitSniffHit(found <-chan sniffHit, grace time.Duration) (sniffHit, bool) {
	if grace <= 0 {
		return sniffHit{}, false
	}
	timer := time.NewTimer(grace)
	defer timer.Stop()
	select {
	case hit := <-found:
		return hit, true
	case <-timer.C:
		return sniffHit{}, false
	}
}

func logSniffPageDiag(ctx context.Context, depth int) {
	if ctx == nil {
		return
	}
	select {
	case <-ctx.Done():
		return
	default:
	}
	var title, platform string
	if err := chromedp.Title(&title).Do(ctx); err != nil {
		return
	}
	_ = chromedp.Evaluate(`navigator.platform`, &platform).Do(ctx)
	iframes := collectIFrameURLs(ctx)
	parseLog("[sniff] diag depth=%d title=%q platform=%q iframes=%d", depth, title, platform, len(iframes))
	for i, f := range iframes {
		if i >= 3 {
			break
		}
		parseLog("[sniff] diag iframe[%d]=%s", i, parsePreview(f, 140))
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

func fallbackDOM(ctx context.Context, rules []model.Rule, isVideo func(string) bool) (out string, hdr map[string]string) {
	defer func() {
		if recover() != nil {
			out, hdr = "", nil
		}
	}()
	if ctx == nil {
		return "", nil
	}
	select {
	case <-ctx.Done():
		return "", nil
	default:
	}
	c := chromedp.FromContext(ctx)
	if c == nil || c.Target == nil {
		return "", nil
	}
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

// sniffPlayAPIResult 解析嗅探到的播放接口 JSON；code≠200 时返回 note 便于打日志。
func sniffPlayAPIResult(body string) (play string, hdr map[string]string, note string) {
	body = strings.TrimSpace(body)
	if body == "" {
		return "", nil, ""
	}
	var obj map[string]json.RawMessage
	if json.Unmarshal([]byte(body), &obj) != nil {
		return "", nil, ""
	}
	if raw, ok := obj["code"]; ok && raw != nil {
		var codeNum float64
		var codeStr string
		switch {
		case json.Unmarshal(raw, &codeNum) == nil:
			if int(codeNum) != 200 {
				msg := jsonStringField(obj, "msg")
				return "", nil, fmt.Sprintf("code=%d msg=%s", int(codeNum), msg)
			}
		case json.Unmarshal(raw, &codeStr) == nil:
			if codeStr != "" && codeStr != "200" {
				msg := jsonStringField(obj, "msg")
				return "", nil, fmt.Sprintf("code=%s msg=%s", codeStr, msg)
			}
		}
	}
	play, hdr = parseJSONPlayBody(body)
	if play == "" {
		return "", nil, ""
	}
	if !strings.HasPrefix(strings.ToLower(play), "http://") && !strings.HasPrefix(strings.ToLower(play), "https://") {
		return "", nil, ""
	}
	return play, hdr, ""
}

// nestedFollowKey 合并同站同资源入口（同 host+vid/id 只跟一次，避免 302 前后各开一层）。
func nestedFollowKey(u string) string {
	u = strings.TrimSpace(u)
	host := strings.ToLower(hostOf(u))
	if host == "" {
		return u
	}
	q, err := url.Parse(u)
	if err != nil {
		return host
	}
	vid := strings.TrimSpace(q.Query().Get("vid"))
	if vid == "" {
		vid = strings.TrimSpace(q.Query().Get("id"))
	}
	if vid != "" {
		return host + "|vid=" + vid
	}
	path := strings.ToLower(q.EscapedPath())
	if path == "" {
		path = "/"
	}
	return host + "|" + path
}

// shouldFollowNestedPlayer 决定是否再开一层嗅探。
// PLAYER 正则；并通用跟进跨站 Document/iframe（MacPlayer 等不保证 URL 含 "player"）。
func shouldFollowNestedPlayer(u, pageURL string, resType network.ResourceType) bool {
	u = strings.TrimSpace(u)
	if u == "" || sameURL(u, pageURL) {
		return false
	}
	if !strings.HasPrefix(strings.ToLower(u), "http://") && !strings.HasPrefix(strings.ToLower(u), "https://") {
		return false
	}
	// 媒体直链不当嵌套页。
	if IsVideoFormat(u) {
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

// shouldParseSniffBody 判断是否值得读响应体抽播放地址。
func shouldParseSniffBody(u, mime string, typ network.ResourceType) bool {
	switch typ {
	case network.ResourceTypeXHR, network.ResourceTypeFetch:
		return true
	}
	return strings.Contains(mime, "json")
}

// sanitizePlayHeaders 处理云播 JSON 里 referer=never 等特殊值。
func sanitizePlayHeaders(h map[string]string) map[string]string {
	if len(h) == 0 {
		return nil
	}
	out := make(map[string]string, len(h))
	for k, v := range h {
		if strings.EqualFold(k, "Referer") && strings.EqualFold(strings.TrimSpace(v), "never") {
			continue
		}
		if strings.TrimSpace(v) == "" {
			continue
		}
		out[k] = v
	}
	if len(out) == 0 {
		return nil
	}
	return out
}

func collectScripts(pageURL, click string, rules []model.Rule) []string {
	var out []string
	if click != "" {
		out = append(out, click)
	}
	// Sniffer.getRule：page host + ?url= 内层 host
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

// sniffProfile 决定 Chromium 以手机还是桌面身份打开页面（跟脚本 UA 档位，而不是宿主写死）。
type sniffProfile struct {
	ua       string
	mobile   bool
	platform string
}

// resolveSniffProfile：优先结果/站点头（含 drpy 魔串）；空头默认 MOBILE_UA。
func resolveSniffProfile(headers map[string]string) sniffProfile {
	raw := strings.TrimSpace(headerValue(headers, "User-Agent"))
	ua := expandDrpyUA(raw)
	if ua == "" {
		ua = sniffUAMobile
	}
	mobile := looksLikeMobileUA(ua)
	platform := "Win64"
	switch {
	case strings.Contains(strings.ToLower(ua), "iphone") || strings.Contains(strings.ToLower(ua), "ipad"):
		platform = "iPhone"
		mobile = true
	case mobile:
		platform = "Linux armv8l"
	}
	return sniffProfile{ua: ua, mobile: mobile, platform: platform}
}

// expandDrpyUA：["MOBILE_UA","PC_UA","UC_UA","IOS_UA","UA"].includes(v) → eval(v)。
func expandDrpyUA(v string) string {
	switch strings.ToUpper(strings.TrimSpace(v)) {
	case "":
		return ""
	case "MOBILE_UA":
		return sniffUAMobile
	case "PC_UA":
		return sniffUAPC
	case "UC_UA":
		return sniffUAUC
	case "IOS_UA":
		return sniffUAIOS
	case "UA":
		return sniffUABare
	default:
		return strings.TrimSpace(v)
	}
}

func looksLikeMobileUA(ua string) bool {
	l := strings.ToLower(ua)
	// 裸 "Mozilla/5.0"（drpy UA）不当移动端。
	if l == "mozilla/5.0" {
		return false
	}
	for _, k := range []string{"mobile", "android", "iphone", "ipad", "ipod", "harmonyos"} {
		if strings.Contains(l, k) {
			return true
		}
	}
	return false
}

// sniffUAMetadata 按脚本 UA 生成 Client Hints；Chrome/平台版本从 UA 解析，不写死。
func sniffUAMetadata(p sniffProfile) *emulation.UserAgentMetadata {
	ver := chromeMajorFromUA(p.ua)
	uaLower := strings.ToLower(p.ua)
	brands := sniffUABrands(uaLower, ver)
	switch {
	case strings.EqualFold(p.platform, "iPhone") || strings.Contains(uaLower, "iphone") || strings.Contains(uaLower, "ipad"):
		return &emulation.UserAgentMetadata{
			Platform:        "iOS",
			PlatformVersion: iosVersionFromUA(p.ua),
			Model:           "iPhone",
			Mobile:          true,
			Brands:          brands,
		}
	case p.mobile:
		return &emulation.UserAgentMetadata{
			Platform:        "Android",
			PlatformVersion: androidVersionFromUA(p.ua),
			Model:           androidModelFromUA(p.ua),
			Mobile:          true,
			Brands:          brands,
		}
	default:
		return &emulation.UserAgentMetadata{
			Platform:        "Windows",
			PlatformVersion: "15.0.0",
			Architecture:    "x86",
			Bitness:         "64",
			Model:           "",
			Mobile:          false,
			Brands:          brands,
		}
	}
}

// sniffUABrands：UC 等非 Chrome 壳不冒充 Google Chrome。
func sniffUABrands(uaLower, ver string) []*emulation.UserAgentBrandVersion {
	if strings.Contains(uaLower, "ucbrowser") {
		return []*emulation.UserAgentBrandVersion{
			{Brand: "Chromium", Version: ver},
			{Brand: "Not.A/Brand", Version: "99"},
		}
	}
	if strings.Contains(uaLower, "iphone") || strings.Contains(uaLower, "ipad") {
		// Safari 系：无 Chrome brand 更贴近真实 iOS。
		if !strings.Contains(uaLower, "crios") && !strings.Contains(uaLower, "chrome/") {
			return []*emulation.UserAgentBrandVersion{
				{Brand: "Not.A/Brand", Version: "99"},
			}
		}
	}
	return []*emulation.UserAgentBrandVersion{
		{Brand: "Chromium", Version: ver},
		{Brand: "Google Chrome", Version: ver},
		{Brand: "Not.A/Brand", Version: "99"},
	}
}

var androidModelRe = regexp.MustCompile(`(?i)Android[^;]*;\s*(?:zh-\w+;\s*)?([^;]+?)\s+Build/`)

func androidModelFromUA(ua string) string {
	if m := androidModelRe.FindStringSubmatch(ua); len(m) > 1 {
		return strings.TrimSpace(m[1])
	}
	return "Pixel 8"
}

var (
	chromeVerRe  = regexp.MustCompile(`(?i)(?:Chrome|CriOS)/(\d+)`)
	androidVerRe = regexp.MustCompile(`(?i)Android\s+(\d+(?:\.\d+)*)`)
	iosVerRe     = regexp.MustCompile(`(?i)(?:iPhone OS|CPU OS)\s+(\d+)[_.](\d+)`)
	safariVerRe  = regexp.MustCompile(`(?i)Version/(\d+(?:\.\d+)*)`)
)

func chromeMajorFromUA(ua string) string {
	if m := chromeVerRe.FindStringSubmatch(ua); len(m) > 1 {
		return m[1]
	}
	// iOS Safari 无 Chrome/；用 Version/ 主版本凑 Client Hints。
	if m := safariVerRe.FindStringSubmatch(ua); len(m) > 1 {
		if i := strings.IndexByte(m[1], '.'); i > 0 {
			return m[1][:i]
		}
		return m[1]
	}
	return "128"
}

func androidVersionFromUA(ua string) string {
	if m := androidVerRe.FindStringSubmatch(ua); len(m) > 1 {
		v := m[1]
		if strings.Count(v, ".") == 0 {
			return v + ".0.0"
		}
		if strings.Count(v, ".") == 1 {
			return v + ".0"
		}
		return v
	}
	return "14.0.0"
}

func iosVersionFromUA(ua string) string {
	if m := iosVerRe.FindStringSubmatch(ua); len(m) > 2 {
		return m[1] + "." + m[2] + ".0"
	}
	if m := safariVerRe.FindStringSubmatch(ua); len(m) > 1 {
		v := m[1]
		if strings.Count(v, ".") == 0 {
			return v + ".0.0"
		}
		if strings.Count(v, ".") == 1 {
			return v + ".0"
		}
		return v
	}
	return "18.0.0"
}

func sniffStealthJS(p sniffProfile) string {
	touch := "0"
	if p.mobile {
		touch = "5"
	}
	platform := p.platform
	if platform == "" {
		platform = "Win64"
	}
	return `(function(){
try{
  Object.defineProperty(navigator,'webdriver',{get:function(){return undefined}});
  Object.defineProperty(navigator,'platform',{get:function(){return '` + platform + `'}});
  Object.defineProperty(navigator,'maxTouchPoints',{get:function(){return ` + touch + `}});
}catch(e){}
})();`
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

// sniffHosts Sniffer.getRule：主 host + ?url= 内层 host，逗号拼接供 ContainOrMatch。
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

func hostsMatched(hostsCSV string, patterns []string) bool {
	if hostsCSV == "" || len(patterns) == 0 {
		return false
	}
	for _, h := range patterns {
		h = strings.TrimSpace(h)
		if h == "" {
			continue
		}
		// Util.containOrMatch(hosts, host)
		if util.ContainOrMatch(hostsCSV, h) {
			return true
		}
	}
	return false
}
