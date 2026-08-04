package spider

import (
	"context"
	"crypto/md5"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	qjs "github.com/buke/quickjs-go"
	"golang.org/x/text/encoding/charmap"
	"golang.org/x/text/encoding/simplifiedchinese"

	"github.com/bobo/KOTV/internal/hostclient"
	"github.com/bobo/KOTV/internal/localproxy"
	"github.com/bobo/KOTV/internal/util"

	_ "embed"
)

//go:embed jslib/cat.js
var jsCat string

//go:embed jslib/http.js
var jsHTTP string

//go:embed jslib/spider.js
var jsSpiderLib string

//go:embed jslib/crypto-js.js
var jsCrypto string

//go:embed jslib/cheerio.min.js
var jsCheerio string

//go:embed jslib/gbk.js
var jsGBK string

//go:embed jslib/similarity.js
var jsSimilarity string

//go:embed jslib/parser.js
var jsParser string

const jsCallTimeout = 45 * time.Second

// jsSpider 基于 QuickJS。
// QuickJS Runtime 绑定创建 goroutine，所有调用经 worker 串行执行。
type jsSpider struct {
	key, api, ext, jar string

	once   sync.Once
	reqCh  chan jsReq
	quitCh chan struct{}
	err    error
	epoch  atomic.Uint64

	activeEpoch  atomic.Uint64
	deadline     atomic.Int64
	inited       atomic.Bool
	cat          atomic.Bool  // 源码含 __jsEvalReturn：CatVod 初始化包装
	activeClient atomic.Value // string

	timerMu sync.Mutex
	timers  map[int32]context.CancelFunc
	timerID atomic.Int32
}

type jsReq struct {
	method   string
	args     []interface{}
	resp     chan jsResp
	epoch    uint64
	clientID string
}

func (s *jsSpider) activeClientID() string {
	v, _ := s.activeClient.Load().(string)
	return v
}

// jsPostMsg 把 JS 脚本消息投到引擎 /postMsg；远端带 userId，本机带 scopeId/clientId。
func jsPostMsg(msg, clientID string) {
	msg = strings.TrimSpace(msg)
	if msg == "" {
		return
	}
	base := fmt.Sprintf("http://127.0.0.1:%d", localproxy.Port())
	q := url.Values{}
	q.Set("msg", msg)
	if uid := hostclient.CurrentUserID(); uid != "" {
		q.Set("userId", uid)
	} else if clientID != "" {
		if strings.HasPrefix(clientID, "u:") || strings.HasPrefix(clientID, "c:") {
			q.Set("scopeId", clientID)
		} else {
			q.Set("clientId", clientID)
		}
	}
	go func() {
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		req, err := http.NewRequestWithContext(ctx, http.MethodGet, base+"/postMsg?"+q.Encode(), nil)
		if err != nil {
			return
		}
		resp, err := http.DefaultClient.Do(req)
		if err != nil {
			return
		}
		_ = resp.Body.Close()
	}()
}

type jsResp struct {
	out string
	err error
}

func (s *jsSpider) alive() bool {
	select {
	case <-s.quitCh:
		return false
	default:
		return true
	}
}

func newJsSpider(key, api, ext, jar string) Spider {
	jsPyMu.Lock()
	defer jsPyMu.Unlock()
	ck := jsPyKey("js", key, api, ext, jar)
	if s, ok := jsPy[ck]; ok {
		if pool, ok := s.(*jsPool); ok {
			return pool
		}
		if js, ok := s.(*jsSpider); ok && js.alive() {
			return s
		}
		delete(jsPy, ck)
	}
	s := newJsPool(key, api, ext, jar)
	jsPy[ck] = s
	return s
}

func (s *jsSpider) startWorker() {
	s.once.Do(func() {
		go s.worker()
	})
}

func (s *jsSpider) worker() {
	s.activeEpoch.Store(s.epoch.Load())
	s.deadline.Store(time.Now().Add(jsCallTimeout).UnixNano())
	if err := s.runWorker(); err != nil {
		s.err = err
	}
	for {
		select {
		case <-s.quitCh:
			return
		case req := <-s.reqCh:
			if s.err != nil {
				req.resp <- jsResp{err: s.err}
				continue
			}
			req.resp <- jsResp{err: fmt.Errorf("JS worker 已停止")}
		}
	}
}

func (s *jsSpider) runWorker() (err error) {
	defer func() {
		if r := recover(); r != nil {
			err = fmt.Errorf("JS worker panic: %v", r)
		}
	}()

	// 对齐 TV JsLoader → dex(jar) → createFun：worker 启动即 parseJar（Init+Proxy）。
	jsLog("[js] worker start key=%s api=%s jar=%s", s.key, s.api, s.resolveJsJar())
	if jar := s.resolveJsJar(); jar != "" {
		if err := EnsureJar(jar); err != nil {
			jsLog("[js] dex(jar) failed key=%s: %v", s.key, err)
			log.Printf("js spider dex(jar) failed key=%s: %v", s.key, err)
		} else {
			jsLog("[js] dex(jar) ok key=%s jar=%s", s.key, jar)
		}
	}

	// 对齐 TV Spider.createCtx：BytecodeModuleLoader + evaluateModule。
	rt := qjs.NewRuntime()
	if rt == nil {
		return fmt.Errorf("QuickJS runtime 创建失败")
	}
	defer rt.Close()
	// 不设 MaxStackSize：与 TV 一致（0=不限）。1MB 对深层爬虫源偏紧，易误杀。
	// 模块加载路径的 CGO panic 已在 kotvModuleNormalize/Loader 里 recover。
	installTVModuleLoader(rt)
	rt.SetInterruptHandler(func() int {
		if s.epoch.Load() != s.activeEpoch.Load() {
			return 1
		}
		if deadline := s.deadline.Load(); deadline > 0 && time.Now().UnixNano() >= deadline {
			return 1
		}
		return 0
	})
	ctx := rt.NewContextWithOptions(qjs.MinimalBootstrap())
	if ctx == nil {
		return fmt.Errorf("QuickJS context 创建失败")
	}
	defer ctx.Close()

	s.registerHost(ctx)
	// 对齐 TV：http.js 作全局脚本；crypto-js 为 UMD，同样按脚本注入全局。
	for _, src := range []string{jsHTTP, jsCrypto} {
		if src == "" {
			continue
		}
		v := ctx.Eval(src)
		if v.IsException() {
			err := ctx.Exception()
			v.Free()
			return fmt.Errorf("加载脚本失败: %w", err)
		}
		v.Free()
	}

	// 对齐 TV Spider.createObj
	isCat, err := createSpiderObj(ctx, s.api)
	if err != nil {
		jsLog("[js] createObj fail key=%s api=%s err=%v", s.key, s.api, err)
		return fmt.Errorf("JS 模块加载失败: %w", err)
	}
	jsLog("[js] createObj ok key=%s cat=%v", s.key, isCat)
	s.cat.Store(isCat)

	spider := ctx.Globals().Get("__JS_SPIDER__")
	if spider == nil || spider.IsNull() || spider.IsUndefined() {
		if spider != nil {
			spider.Free()
		}
		fn := ctx.Globals().Get("__jsEvalReturn")
		if fn != nil && fn.IsFunction() {
			ret := fn.Execute(ctx.NewUndefined())
			fn.Free()
			if ret != nil && !ret.IsException() {
				spider = ret
			} else if ret != nil {
				ret.Free()
			}
		}
	}
	if spider == nil || spider.IsNull() || spider.IsUndefined() {
		alt := ctx.Globals().Get("spider")
		if spider != nil {
			spider.Free()
		}
		spider = alt
	}
	if spider == nil || spider.IsNull() || spider.IsUndefined() {
		if spider != nil {
			spider.Free()
		}
		jsLog("[js] missing __JS_SPIDER__ key=%s api=%s", s.key, s.api)
		return fmt.Errorf("JS 爬虫未导出 __JS_SPIDER__")
	}
	defer func() {
		if spider != nil && !spider.IsNull() && !spider.IsUndefined() {
			_, _ = s.callOn(ctx, spider, "destroy")
			spider.Free()
		}
		s.clearTimers()
	}()
	// 对齐 TV：createObj 后立即 init
	if _, err := s.callOn(ctx, spider, "init", s.initArg()); err != nil {
		jsLog("[js] init fail key=%s err=%v", s.key, err)
		return fmt.Errorf("JS init 失败: %w", err)
	}
	jsLog("[js] init ok key=%s", s.key)
	s.inited.Store(true)

	for {
		select {
		case <-s.quitCh:
			return nil
		case req := <-s.reqCh:
			if req.epoch != s.epoch.Load() {
				req.resp <- jsResp{err: ErrScriptInterrupted}
				continue
			}
			s.activeClient.Store(req.clientID)
			done := hostclient.Enter(req.clientID)
			s.activeEpoch.Store(req.epoch)
			s.deadline.Store(time.Now().Add(jsCallTimeout).UnixNano())
			args := req.args
			if req.method == "init" {
				if s.inited.Load() {
					// 已在 createObj 后 init 过，避免双重初始化
					done()
					s.activeClient.Store("")
					req.resp <- jsResp{out: "{}", err: nil}
					continue
				}
				args = []interface{}{s.initArg()}
			}
			out, err := s.callOn(ctx, spider, req.method, args...)
			if req.method == "init" && err == nil {
				s.inited.Store(true)
			}
			if err != nil {
				jsLog("[js] call fail key=%s method=%s err=%v", s.key, req.method, err)
			} else {
				jsLog("[js] call ok key=%s method=%s out=%s", s.key, req.method, jsPreview(out, 200))
			}
			done()
			s.activeClient.Store("")
			req.resp <- jsResp{out: out, err: err}
		}
	}
}

// initArg CatVod 脚本包装 {stype,skey,ext}。
func (s *jsSpider) initArg() interface{} {
	ext := strings.TrimSpace(s.ext)
	var extVal interface{} = ext
	if ext != "" && (strings.HasPrefix(ext, "{") || strings.HasPrefix(ext, "[")) {
		var parsed interface{}
		if json.Unmarshal([]byte(ext), &parsed) == nil {
			extVal = parsed
		}
	}
	if !s.cat.Load() {
		return extVal
	}
	return map[string]interface{}{
		"stype": 3,
		"skey":  s.key,
		"ext":   extVal,
	}
}

// looksLikeESModule 判断源码是否已是 ESM（否则补 export default）。
func looksLikeESModule(source string) bool {
	trim := strings.TrimSpace(source)
	return strings.HasPrefix(trim, "import ") ||
		strings.HasPrefix(trim, "import{") ||
		strings.Contains(source, "\nimport ") ||
		strings.Contains(source, "\nimport{") ||
		strings.Contains(source, "export default") ||
		strings.Contains(source, "export {") ||
		strings.Contains(source, "export{") ||
		strings.Contains(source, "export function") ||
		strings.Contains(source, "export async function") ||
		strings.Contains(source, "export class") ||
		strings.Contains(source, "export const") ||
		strings.Contains(source, "export let") ||
		strings.Contains(source, "export var")
}

func (s *jsSpider) fetchScript() (string, error) {
	content := moduleFetch(s.api)
	if content == "" {
		return "", fmt.Errorf("JS api 内容为空: %s", s.api)
	}
	return content, nil
}

func (s *jsSpider) callOn(ctx *qjs.Context, spider *qjs.Value, method string, args ...interface{}) (string, error) {
	if spider == nil {
		return "{}", fmt.Errorf("spider 未初始化")
	}
	fn := spider.Get(method)
	if fn == nil || !fn.IsFunction() {
		if fn != nil {
			fn.Free()
		}
		// init/destroy/action/sniffer/isVideo 可选（对齐 TV 默认空实现）
		if method == "init" || method == "destroy" || method == "action" ||
			method == "sniffer" || method == "isVideo" {
			return "", nil
		}
		return "{}", fmt.Errorf("方法不存在: %s", method)
	}
	defer fn.Free()

	jsArgs := make([]*qjs.Value, len(args))
	for i, a := range args {
		v, err := ctx.Marshal(a)
		if err != nil {
			v = ctx.NewString(fmt.Sprint(a))
		}
		jsArgs[i] = v
	}
	defer func() {
		for _, a := range jsArgs {
			a.Free()
		}
	}()

	ret := fn.Execute(spider, jsArgs...)
	if ret == nil {
		return "{}", nil
	}
	if ret.IsPromise() {
		ret = ctx.Await(ret)
		if ret == nil {
			return "{}", fmt.Errorf("Promise 执行失败")
		}
	}
	defer ret.Free()
	if ret.IsException() {
		return "{}", ctx.Exception()
	}
	if ret.IsString() {
		return ret.String(), nil
	}
	if ret.IsBool() {
		if ret.ToBool() {
			return "true", nil
		}
		return "false", nil
	}
	if ret.IsObject() || ret.IsArray() {
		return ret.JSONStringify(), nil
	}
	return ret.String(), nil
}

func (s *jsSpider) registerHost(ctx *qjs.Context) {
	if ctx == nil {
		return
	}
	g := ctx.Globals()
	g.Set("md5X", ctx.NewFunction(func(c *qjs.Context, this *qjs.Value, args []*qjs.Value) *qjs.Value {
		text := ""
		if len(args) > 0 {
			text = args[0].String()
		}
		sum := md5.Sum([]byte(text))
		return c.NewString(hex.EncodeToString(sum[:]))
	}))
	g.Set("joinUrl", ctx.NewFunction(func(c *qjs.Context, this *qjs.Value, args []*qjs.Value) *qjs.Value {
		parent, child := "", ""
		if len(args) > 0 {
			parent = args[0].String()
		}
		if len(args) > 1 {
			child = args[1].String()
		}
		// 对齐 TV Global.joinUrl → UriUtil.resolve
		return c.NewString(util.UriResolve(parent, child))
	}))
	g.Set("getPort", ctx.NewFunction(func(c *qjs.Context, this *qjs.Value, args []*qjs.Value) *qjs.Value {
		return c.NewInt32(int32(localproxy.Port()))
	}))
	g.Set("getClientId", ctx.NewFunction(func(c *qjs.Context, this *qjs.Value, args []*qjs.Value) *qjs.Value {
		return c.NewString(hostclient.ScopeID())
	}))
	g.Set("postMsg", ctx.NewFunction(func(c *qjs.Context, this *qjs.Value, args []*qjs.Value) *qjs.Value {
		msg := ""
		if len(args) > 0 {
			msg = args[0].String()
		}
		jsPostMsg(msg, hostclient.ScopeID())
		return c.NewBool(true)
	}))
	g.Set("getProxy", ctx.NewFunction(func(c *qjs.Context, this *qjs.Value, args []*qjs.Value) *qjs.Value {
		// 对齐 TV Global.getProxy：Proxy.getUrl(local)+"?do=js"
		local := true
		if len(args) > 0 && !args[0].IsUndefined() && !args[0].IsNull() {
			local = args[0].ToBool()
		}
		return c.NewString(localproxy.BaseURL(local) + "?do=js")
	}))
	g.Set("js2Proxy", ctx.NewFunction(func(c *qjs.Context, this *qjs.Value, args []*qjs.Value) *qjs.Value {
		// 对齐 TV Global.js2Proxy：getProxy(!dynamic)+&from=catvod&…
		dynamic, siteType, siteKey, u, headerJSON := false, 0, s.key, "", "{}"
		if len(args) > 0 {
			dynamic = args[0].ToBool()
		}
		if len(args) > 1 {
			siteType = int(args[1].Int32())
		}
		if len(args) > 2 {
			siteKey = args[2].String()
		}
		if len(args) > 3 {
			u = args[3].String()
		}
		if len(args) > 4 && args[4] != nil && !args[4].IsUndefined() && !args[4].IsNull() {
			if args[4].IsObject() {
				headerJSON = args[4].JSONStringify()
			} else {
				headerJSON = args[4].String()
			}
		}
		return c.NewString(fmt.Sprintf("%s?do=js&from=catvod&siteType=%d&siteKey=%s&header=%s&url=%s",
			localproxy.BaseURL(!dynamic),
			siteType,
			siteKey, // 对齐 TV：siteKey 不 URLEncode
			javaURLEncode(headerJSON),
			javaURLEncode(u),
		))
	}))
	g.Set("s2t", ctx.NewFunction(func(c *qjs.Context, this *qjs.Value, args []*qjs.Value) *qjs.Value {
		if len(args) > 0 {
			return c.NewString(s2t(args[0].String()))
		}
		return c.NewString("")
	}))
	g.Set("t2s", ctx.NewFunction(func(c *qjs.Context, this *qjs.Value, args []*qjs.Value) *qjs.Value {
		if len(args) > 0 {
			return c.NewString(t2s(args[0].String()))
		}
		return c.NewString("")
	}))
	g.Set("aesX", ctx.NewFunction(func(c *qjs.Context, this *qjs.Value, args []*qjs.Value) *qjs.Value {
		mode, input, key := "", "", ""
		encrypt, inB64, outB64 := true, false, false
		var iv *string
		if len(args) > 0 {
			mode = args[0].String()
		}
		if len(args) > 1 {
			encrypt = args[1].ToBool()
		}
		if len(args) > 2 {
			input = args[2].String()
		}
		if len(args) > 3 {
			inB64 = args[3].ToBool()
		}
		if len(args) > 4 {
			key = args[4].String()
		}
		// 对齐 TV：iv == null 时 Cipher.init 不带 IvParameterSpec（ECB）
		if len(args) > 5 && args[5] != nil && !args[5].IsNull() && !args[5].IsUndefined() {
			s := args[5].String()
			iv = &s
		}
		if len(args) > 6 {
			outB64 = args[6].ToBool()
		}
		return c.NewString(aesX(mode, encrypt, input, inB64, key, iv, outB64))
	}))
	g.Set("rsaX", ctx.NewFunction(func(c *qjs.Context, this *qjs.Value, args []*qjs.Value) *qjs.Value {
		mode, input, key := "", "", ""
		pub, encrypt, inB64, outB64 := false, true, false, false
		if len(args) > 0 {
			mode = args[0].String()
		}
		if len(args) > 1 {
			pub = args[1].ToBool()
		}
		if len(args) > 2 {
			encrypt = args[2].ToBool()
		}
		if len(args) > 3 {
			input = args[3].String()
		}
		if len(args) > 4 {
			inB64 = args[4].ToBool()
		}
		if len(args) > 5 {
			key = args[5].String()
		}
		if len(args) > 6 {
			outB64 = args[6].ToBool()
		}
		return c.NewString(rsaX(mode, pub, encrypt, input, inB64, key, outB64))
	}))
	g.Set("req", ctx.NewFunction(s.jsReq))
	g.Set("_http", ctx.NewFunction(s.jsReq))
	g.Set("_httpAsync", ctx.NewFunction(s.jsReqAsync))
	g.Set("_sleep", ctx.NewFunction(func(c *qjs.Context, this *qjs.Value, args []*qjs.Value) *qjs.Value {
		delay := 0
		if len(args) > 0 {
			delay = int(args[0].Int32())
		}
		return c.NewPromise(func(resolve, reject func(*qjs.Value)) {
			go func() {
				time.Sleep(time.Duration(max(delay, 0)) * time.Millisecond)
				c.Schedule(func(inner *qjs.Context) {
					value := inner.NewUndefined()
					resolve(value)
					value.Free()
				})
			}()
		})
	}))
	// 对齐 TV Global.setTimeout：宿主 Timer，Destroy 时全部取消
	g.Set("setTimeout", ctx.NewFunction(func(c *qjs.Context, this *qjs.Value, args []*qjs.Value) *qjs.Value {
		if len(args) == 0 || !args[0].IsFunction() {
			return c.NewInt32(0)
		}
		delay := 0
		if len(args) > 1 {
			delay = int(args[1].Int32())
		}
		id := s.timerID.Add(1)
		// 用 JS 对象存回调（SetIdx 会 Dup），避免 args 返回后被释放
		store := c.Globals().Get("__kotvTimers")
		if store == nil || store.IsUndefined() || store.IsNull() {
			if store != nil {
				store.Free()
			}
			store = c.NewObject()
			c.Globals().Set("__kotvTimers", store)
		}
		store.SetIdx(int64(id), args[0])
		store.Free()

		tctx, cancel := context.WithCancel(context.Background())
		s.timerMu.Lock()
		s.timers[id] = cancel
		s.timerMu.Unlock()
		go func() {
			timer := time.NewTimer(time.Duration(max(delay, 0)) * time.Millisecond)
			defer timer.Stop()
			select {
			case <-tctx.Done():
				c.Schedule(func(inner *qjs.Context) {
					st := inner.Globals().Get("__kotvTimers")
					if st != nil && !st.IsUndefined() {
						st.DeleteIdx(uint32(id))
						st.Free()
					}
				})
				return
			case <-timer.C:
			}
			c.Schedule(func(inner *qjs.Context) {
				s.timerMu.Lock()
				delete(s.timers, id)
				s.timerMu.Unlock()
				st := inner.Globals().Get("__kotvTimers")
				if st == nil || st.IsUndefined() {
					if st != nil {
						st.Free()
					}
					return
				}
				fn := st.GetIdx(int64(id))
				st.DeleteIdx(uint32(id))
				st.Free()
				if fn != nil && fn.IsFunction() {
					ret := fn.Execute(inner.NewUndefined())
					if ret != nil {
						ret.Free()
					}
				}
				if fn != nil {
					fn.Free()
				}
			})
		}()
		return c.NewInt32(id)
	}))
	g.Set("clearTimeout", ctx.NewFunction(func(c *qjs.Context, this *qjs.Value, args []*qjs.Value) *qjs.Value {
		if len(args) > 0 {
			id := args[0].Int32()
			s.timerMu.Lock()
			if cancel, ok := s.timers[id]; ok {
				cancel()
				delete(s.timers, id)
			}
			s.timerMu.Unlock()
			st := c.Globals().Get("__kotvTimers")
			if st != nil && !st.IsUndefined() {
				st.DeleteIdx(uint32(id))
				st.Free()
			} else if st != nil {
				st.Free()
			}
		}
		return c.NewUndefined()
	}))
	console := ctx.NewObject()
	logFn := func(prefix string) *qjs.Value {
		return ctx.NewFunction(func(c *qjs.Context, this *qjs.Value, args []*qjs.Value) *qjs.Value {
			parts := make([]string, len(args))
			for i, a := range args {
				parts[i] = a.String()
			}
			// 必须走 log（stderr）；fmt.Println 走 stdout，Flutter 侧已丢弃。
			jsLog("%s %s", prefix, strings.Join(parts, " "))
			return c.NewUndefined()
		})
	}
	console.Set("log", logFn("[js]"))
	console.Set("error", logFn("[js-err]"))
	console.Set("warn", logFn("[js-warn]"))
	console.Set("info", logFn("[js-info]"))
	console.Set("debug", logFn("[js-debug]"))
	g.Set("console", console)

	// local.get/set/delete — 对齐 TV：全局 cache_rule_key，无 siteKey
	local := ctx.NewObject()
	local.Set("get", ctx.NewFunction(func(c *qjs.Context, this *qjs.Value, args []*qjs.Value) *qjs.Value {
		rule, key := "", ""
		if len(args) > 0 {
			rule = args[0].String()
		}
		if len(args) > 1 {
			key = args[1].String()
		}
		return c.NewString(jsLocalGet(rule, key))
	}))
	local.Set("set", ctx.NewFunction(func(c *qjs.Context, this *qjs.Value, args []*qjs.Value) *qjs.Value {
		rule, key, value := "", "", ""
		if len(args) > 0 {
			rule = args[0].String()
		}
		if len(args) > 1 {
			key = args[1].String()
		}
		if len(args) > 2 {
			value = args[2].String()
		}
		jsLocalSet(rule, key, value)
		return c.NewUndefined()
	}))
	local.Set("delete", ctx.NewFunction(func(c *qjs.Context, this *qjs.Value, args []*qjs.Value) *qjs.Value {
		rule, key := "", ""
		if len(args) > 0 {
			rule = args[0].String()
		}
		if len(args) > 1 {
			key = args[1].String()
		}
		jsLocalDelete(rule, key)
		return c.NewUndefined()
	}))
	g.Set("local", local)

	// xpath 宿主（对齐 jar Function 的 / 规则）；parser.js 优先调用。
	g.Set("__xpathHtml", ctx.NewFunction(func(c *qjs.Context, this *qjs.Value, args []*qjs.Value) *qjs.Value {
		html, expr := "", ""
		if len(args) > 0 {
			html = args[0].String()
		}
		if len(args) > 1 {
			expr = args[1].String()
		}
		return c.NewString(xpathFirstHTML(html, expr))
	}))
	g.Set("__xpathText", ctx.NewFunction(func(c *qjs.Context, this *qjs.Value, args []*qjs.Value) *qjs.Value {
		html, expr := "", ""
		if len(args) > 0 {
			html = args[0].String()
		}
		if len(args) > 1 {
			expr = args[1].String()
		}
		return c.NewString(xpathFirstText(html, expr))
	}))
	g.Set("__xpathList", ctx.NewFunction(func(c *qjs.Context, this *qjs.Value, args []*qjs.Value) *qjs.Value {
		html, expr := "", ""
		if len(args) > 0 {
			html = args[0].String()
		}
		if len(args) > 1 {
			expr = args[1].String()
		}
		list := xpathAllHTML(html, expr)
		v, err := c.Marshal(list)
		if err != nil || v == nil {
			empty, _ := c.Marshal([]string{})
			return empty
		}
		return v
	}))

	// 对齐 TV createFun：优先走 jar 内 Parser/Function（bridge jsParse），失败由 parser.js 回落。
	jar := s.resolveJsJar()
	g.Set("__jarPdfh", ctx.NewFunction(func(c *qjs.Context, this *qjs.Value, args []*qjs.Value) *qjs.Value {
		html, rule := "", ""
		if len(args) > 0 {
			html = args[0].String()
		}
		if len(args) > 1 {
			rule = args[1].String()
		}
		v, _, err := JsParse(jar, "pdfh", html, rule, "", "", "")
		if err != nil {
			return c.NewUndefined()
		}
		return c.NewString(v)
	}))
	g.Set("__jarPd", ctx.NewFunction(func(c *qjs.Context, this *qjs.Value, args []*qjs.Value) *qjs.Value {
		html, rule, url := "", "", ""
		if len(args) > 0 {
			html = args[0].String()
		}
		if len(args) > 1 {
			rule = args[1].String()
		}
		if len(args) > 2 {
			url = args[2].String()
		}
		v, _, err := JsParse(jar, "pd", html, rule, url, "", "")
		if err != nil {
			return c.NewUndefined()
		}
		return c.NewString(v)
	}))
	g.Set("__jarPdfa", ctx.NewFunction(func(c *qjs.Context, this *qjs.Value, args []*qjs.Value) *qjs.Value {
		html, rule := "", ""
		if len(args) > 0 {
			html = args[0].String()
		}
		if len(args) > 1 {
			rule = args[1].String()
		}
		_, list, err := JsParse(jar, "pdfa", html, rule, "", "", "")
		if err != nil {
			return c.NewUndefined()
		}
		v, mErr := c.Marshal(list)
		if mErr != nil || v == nil {
			empty, _ := c.Marshal([]string{})
			return empty
		}
		return v
	}))
	g.Set("__jarPdfl", ctx.NewFunction(func(c *qjs.Context, this *qjs.Value, args []*qjs.Value) *qjs.Value {
		html, rule, texts, urls, url := "", "", "", "", ""
		if len(args) > 0 {
			html = args[0].String()
		}
		if len(args) > 1 {
			rule = args[1].String()
		}
		if len(args) > 2 {
			texts = args[2].String()
		}
		if len(args) > 3 {
			urls = args[3].String()
		}
		if len(args) > 4 {
			url = args[4].String()
		}
		_, list, err := JsParse(jar, "pdfl", html, rule, url, texts, urls)
		if err != nil {
			return c.NewUndefined()
		}
		v, mErr := c.Marshal(list)
		if mErr != nil || v == nil {
			empty, _ := c.Marshal([]string{})
			return empty
		}
		return v
	}))
}

func (s *jsSpider) resolveJsJar() string {
	if j := strings.TrimSpace(s.jar); j != "" {
		return j
	}
	jarMu.Lock()
	defer jarMu.Unlock()
	return jarPath
}

func (s *jsSpider) jsReq(c *qjs.Context, this *qjs.Value, args []*qjs.Value) *qjs.Value {
	u, options := parseJSRequest(args)
	var complete *qjs.Value
	if len(args) > 1 && args[1].IsObject() {
		if fn := args[1].Get("complete"); fn != nil && fn.IsFunction() {
			complete = fn
		} else if fn != nil {
			fn.Free()
		}
	}
	if complete != nil {
		// 有 complete 时异步回调
		go func() {
			result := doJSRequest(u, options)
			c.Schedule(func(inner *qjs.Context) {
				value, err := inner.Marshal(result)
				if err != nil {
					value = inner.NewObject()
				}
				ret := complete.Execute(inner.NewUndefined(), value)
				if ret != nil {
					ret.Free()
				}
				value.Free()
				complete.Free()
			})
		}()
		return c.NewUndefined()
	}
	result := doJSRequest(u, options)
	v, _ := c.Marshal(result)
	return v
}

func (s *jsSpider) jsReqAsync(c *qjs.Context, this *qjs.Value, args []*qjs.Value) *qjs.Value {
	u, options := parseJSRequest(args)
	return c.NewPromise(func(resolve, reject func(*qjs.Value)) {
		go func() {
			result := doJSRequest(u, options)
			c.Schedule(func(inner *qjs.Context) {
				value, err := inner.Marshal(result)
				if err != nil {
					value = inner.NewObject()
				}
				resolve(value)
				value.Free()
			})
		}()
	})
}

type jsHTTPRequest struct {
	Method, Body, Data, PostType, Charset string
	Headers                               map[string]string
	Buffer, Redirect, Timeout             int
}

func parseJSRequest(args []*qjs.Value) (string, jsHTTPRequest) {
	u := ""
	if len(args) > 0 {
		u = args[0].String()
	}
	options := jsHTTPRequest{Method: "GET", Headers: map[string]string{}, Buffer: 0, Redirect: 1, Timeout: 10000, PostType: "json"}
	if len(args) > 1 && args[1].IsObject() {
		if m := args[1].Get("method"); m != nil && !m.IsUndefined() {
			options.Method = strings.ToUpper(m.String())
			m.Free()
		}
		if h := args[1].Get("headers"); h != nil && h.IsObject() {
			raw := h.JSONStringify()
			_ = json.Unmarshal([]byte(raw), &options.Headers)
			h.Free()
		}
		if b := args[1].Get("body"); b != nil && !b.IsUndefined() && !b.IsNull() {
			options.Body = b.String()
			b.Free()
		} else if b := args[1].Get("data"); b != nil && !b.IsUndefined() && !b.IsNull() {
			options.Data = b.JSONStringify()
			if b.IsString() {
				options.Data = b.String()
			}
			b.Free()
		}
		parseIntOption := func(name string, dst *int) {
			if v := args[1].Get(name); v != nil && !v.IsUndefined() && !v.IsNull() {
				*dst = int(v.Int32())
				v.Free()
			} else if v != nil {
				v.Free()
			}
		}
		parseIntOption("buffer", &options.Buffer)
		parseIntOption("redirect", &options.Redirect)
		parseIntOption("timeout", &options.Timeout)
		if v := args[1].Get("postType"); v != nil && !v.IsUndefined() {
			options.PostType = strings.ToLower(v.String())
			v.Free()
		} else if v != nil {
			v.Free()
		}
		if v := args[1].Get("charset"); v != nil && !v.IsUndefined() {
			options.Charset = v.String()
			v.Free()
		} else if v != nil {
			v.Free()
		}
	}
	if options.Method == "HEADER" {
		options.Method = "HEAD"
	}
	return u, options
}

func doJSRequest(u string, options jsHTTPRequest) map[string]interface{} {
	// 对齐 TV Connect.error：code 为空字符串（脚本 if (!res.code) 才成立）
	jsError := func() map[string]interface{} {
		return map[string]interface{}{
			"code":    "",
			"content": "",
			"headers": map[string]interface{}{},
		}
	}
	u = strings.TrimSpace(u)
	// 脚本常带 Referer 却传相对 path（如 /play/xxx.html）；按 Referer/Origin 拼绝对地址。
	if u != "" && !strings.Contains(u, "://") && !strings.HasPrefix(strings.ToLower(u), "data:") {
		ref := ""
		for _, k := range []string{"Referer", "referer", "Origin", "origin"} {
			if v := strings.TrimSpace(options.Headers[k]); strings.HasPrefix(v, "http") {
				ref = v
				break
			}
		}
		if ref != "" {
			if abs := util.UriResolve(ref, u); abs != "" && strings.Contains(abs, "://") {
				jsLog("[js-http] resolve relative %s + %s → %s", ref, u, abs)
				u = abs
			}
		}
	}
	body := options.Body
	if options.Data != "" {
		switch options.PostType {
		case "form":
			var values map[string]interface{}
			if json.Unmarshal([]byte(options.Data), &values) == nil {
				form := url.Values{}
				for k, v := range values {
					form.Set(k, fmt.Sprint(v))
				}
				body = form.Encode()
				if options.Headers["Content-Type"] == "" {
					options.Headers["Content-Type"] = "application/x-www-form-urlencoded"
				}
			}
		case "form-data":
			var values map[string]interface{}
			if json.Unmarshal([]byte(options.Data), &values) == nil {
				var buf strings.Builder
				boundary := "----kotv-form-boundary"
				for k, v := range values {
					fmt.Fprintf(&buf, "--%s\r\nContent-Disposition: form-data; name=%q\r\n\r\n%v\r\n", boundary, k, v)
				}
				fmt.Fprintf(&buf, "--%s--\r\n", boundary)
				body = buf.String()
				if options.Headers["Content-Type"] == "" {
					options.Headers["Content-Type"] = "multipart/form-data; boundary=" + boundary
				}
			}
		default:
			body = options.Data
			if options.Headers["Content-Type"] == "" {
				options.Headers["Content-Type"] = "application/json; charset=utf-8"
			}
		}
	}
	req, err := http.NewRequest(options.Method, u, strings.NewReader(body))
	if err != nil {
		return jsError()
	}
	for k, v := range options.Headers {
		req.Header.Set(k, v)
	}
	// 对齐 TV：脚本未带 UA 时走 OkHttp 默认类 UA，避免 Go-http-client 被拦
	if req.Header.Get("User-Agent") == "" {
		req.Header.Set("User-Agent", "okhttp/4.12.0")
	}
	client := &http.Client{
		Timeout:   time.Duration(max(options.Timeout, 0)) * time.Millisecond,
		Transport: jsRequestTransport(),
	}
	if options.Timeout <= 0 {
		client.Timeout = util.GetClient().Timeout
	}
	if options.Redirect == 0 {
		client.CheckRedirect = func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }
	} else {
		// 对齐 TV network interceptor：跟随重定向时仍记录 302→原 URL 映射
		client.CheckRedirect = trackJSRedirects
	}
	resp, err := client.Do(req)
	if err != nil {
		jsLog("[js-http] fail method=%s url=%s err=%v", options.Method, u, err)
		return jsError()
	}
	defer resp.Body.Close()
	b := drainBody(resp)
	b = decodeJSContentEncoding(resp.Header.Get("Content-Encoding"), b)
	code, hdrSrc, b := applyJSRedirectDance(u, resp, b)
	if code == 0 || code >= 400 {
		jsLog("[js-http] bad status method=%s url=%s code=%d bytes=%d", options.Method, u, code, len(b))
	} else {
		jsLog("[js-http] ok method=%s url=%s code=%d bytes=%d", options.Method, u, code, len(b))
	}
	result := map[string]interface{}{
		"code":    code,
		"headers": map[string]interface{}{},
		"content": "",
	}
	hdrs := map[string]interface{}{}
	for k, vv := range hdrSrc {
		// 对齐 OkHttp toMultimap：头名小写，供 headers['content-type'] 等读取
		lk := strings.ToLower(k)
		if len(vv) == 1 {
			hdrs[lk] = vv[0]
		} else if len(vv) > 1 {
			hdrs[lk] = vv
		}
	}
	result["headers"] = hdrs
	// 对齐 TV Req.getCharset：只看请求头 Content-Type
	charset := options.Charset
	if charset == "" {
		charset = charsetFromHeaders(options.Headers)
	}
	switch options.Buffer {
	case 1:
		// 对齐 TV JSUtil.toArray(byte[])：Java signed byte → -128..127
		content := make([]int, len(b))
		for i := range b {
			content[i] = int(int8(b[i]))
		}
		result["content"] = content
	case 2:
		result["content"] = base64Std(b)
	case 3:
		// 对齐 TV：原始 byte[] → QuickJS ArrayBuffer（Marshal []byte）
		result["content"] = append([]byte(nil), b...)
	default:
		result["content"] = decodeJSResponse(b, charset, "")
	}
	return result
}

// javaURLEncode 对齐 Java URLEncoder.encode(…, UTF-8)：空格为 +。
func javaURLEncode(s string) string {
	return strings.ReplaceAll(url.QueryEscape(s), "%20", "+")
}

func charsetFromHeaders(headers map[string]string) string {
	for _, key := range []string{"Content-Type", "content-type"} {
		if v := headers[key]; v != "" {
			for _, part := range strings.Split(v, ";") {
				part = strings.TrimSpace(part)
				if strings.HasPrefix(strings.ToLower(part), "charset=") {
					return strings.Trim(strings.TrimSpace(part[8:]), `"`)
				}
			}
		}
	}
	return "UTF-8"
}

func (s *jsSpider) invoke(method string, args ...interface{}) (string, error) {
	s.startWorker()
	resp := make(chan jsResp, 1)
	epoch := s.epoch.Load()
	cid := hostclient.ScopeID()
	start := time.Now()
	select {
	case <-s.quitCh:
		return "{}", fmt.Errorf("spider 已销毁")
	case s.reqCh <- jsReq{method: method, args: args, resp: resp, epoch: epoch, clientID: cid}:
	}
	select {
	case r := <-resp:
		cost := time.Since(start).Truncate(time.Millisecond)
		if s.epoch.Load() != epoch {
			jsLog("[js] invoke interrupted key=%s method=%s cost=%s", s.key, method, cost)
			return "{}", ErrScriptInterrupted
		}
		if r.err != nil {
			jsLog("[js] invoke err key=%s method=%s cost=%s err=%v", s.key, method, cost, r.err)
			return "{}", r.err
		}
		// action/sniffer/isVideo 允许空串（对齐 TV null/false）；其它业务空结果抬成 "{}"
		if r.out == "" && method != "action" && method != "sniffer" && method != "isVideo" {
			jsLog("[js] invoke empty→{} key=%s method=%s cost=%s", s.key, method, cost)
			return "{}", nil
		}
		jsLog("[js] invoke ok key=%s method=%s cost=%s out=%s", s.key, method, cost, jsPreview(r.out, 200))
		return r.out, nil
	case <-time.After(jsCallTimeout):
		s.interrupt()
		jsLog("[js] invoke timeout key=%s method=%s after=%s", s.key, method, jsCallTimeout)
		return "{}", fmt.Errorf("JavaScript %s 调用超过 %s", method, jsCallTimeout)
	}
}

func (s *jsSpider) interrupt() {
	s.epoch.Add(1)
}

func (s *jsSpider) Init(ext string) error {
	s.ext = ext
	// EnsureJar 已在 runWorker 对齐 TV dex；此处保留以防 Init 早于 worker。
	if jar := s.resolveJsJar(); jar != "" {
		if err := EnsureJar(jar); err != nil {
			log.Printf("js spider dex(jar) failed key=%s: %v", s.key, err)
		}
	}
	_, err := s.invoke("init", ext)
	return err
}
func (s *jsSpider) HomeContent(filter bool) (string, error) {
	return s.invoke("home", filter)
}
func (s *jsSpider) HomeVideoContent() (string, error) {
	return s.invoke("homeVod")
}
func (s *jsSpider) CategoryContent(tid, pg string, filter bool, extend map[string]string) (string, error) {
	return s.invoke("category", tid, pg, filter, extend)
}
func (s *jsSpider) DetailContent(ids []string) (string, error) {
	id := ""
	if len(ids) > 0 {
		id = ids[0]
	}
	return s.invoke("detail", id)
}
func (s *jsSpider) SearchContent(key string, quick bool, pg string) (string, error) {
	return s.invoke("search", key, quick, pg)
}
func (s *jsSpider) PlayerContent(flag, id string, vipFlags []string) (string, error) {
	return s.invoke("play", flag, id, vipFlags)
}
func (s *jsSpider) LiveContent(url string) (string, error) {
	return s.invoke("live", url)
}
func (s *jsSpider) Proxy(params map[string]string) (int, string, []byte, map[string]string, error) {
	// from=catvod 走数组路径参数
	var raw string
	var err error
	if params["from"] == "catvod" {
		parts := strings.Split(params["url"], "/")
		header := params["header"]
		if header == "" {
			header = "{}"
		}
		var headerObj interface{}
		if json.Unmarshal([]byte(header), &headerObj) != nil {
			headerObj = header
		}
		raw, err = s.invoke("proxy", parts, headerObj)
	} else {
		raw, err = s.invoke("proxy", params)
	}
	if err != nil {
		return 0, "", nil, nil, err
	}
	status, contentType, body, headers, parseErr := parseCatvodProxy(raw)
	return status, contentType, body, headers, parseErr
}

func (s *jsSpider) Action(action string) (string, error) {
	return s.invoke("action", action)
}

func (s *jsSpider) ManualVideoCheck() (bool, error) {
	out, err := s.invoke("sniffer")
	if err != nil {
		return false, err
	}
	return parseJSTruthy(out), nil
}

func (s *jsSpider) IsVideoFormat(u string) (bool, error) {
	out, err := s.invoke("isVideo", u)
	if err != nil {
		return false, err
	}
	return parseJSTruthy(out), nil
}

func parseJSTruthy(s string) bool {
	s = strings.TrimSpace(strings.ToLower(s))
	switch s {
	case "1", "true", "yes", "ok":
		return true
	default:
		return false
	}
}

func (s *jsSpider) Destroy() {
	defer func() { _ = recover() }()
	s.clearTimers()
	s.interrupt()
	select {
	case <-s.quitCh:
	default:
		close(s.quitCh)
	}
}

func (s *jsSpider) clearTimers() {
	s.timerMu.Lock()
	defer s.timerMu.Unlock()
	for id, cancel := range s.timers {
		cancel()
		delete(s.timers, id)
	}
}

func decodeJSResponse(data []byte, optionCharset, contentType string) string {
	charset := strings.TrimSpace(optionCharset)
	if charset == "" {
		for _, part := range strings.Split(contentType, ";") {
			if key, value, ok := strings.Cut(strings.TrimSpace(part), "="); ok && strings.EqualFold(strings.TrimSpace(key), "charset") {
				charset = strings.Trim(strings.TrimSpace(value), `"`)
				break
			}
		}
	}
	switch strings.ToLower(strings.ReplaceAll(charset, "_", "-")) {
	case "", "utf-8", "utf8":
		return string(data)
	case "gbk", "gb2312", "gb18030":
		if text, err := simplifiedchinese.GBK.NewDecoder().Bytes(data); err == nil {
			return string(text)
		}
	case "iso-8859-1", "latin1", "latin-1":
		if text, err := charmap.ISO8859_1.NewDecoder().Bytes(data); err == nil {
			return string(text)
		}
	}
	return string(data)
}
