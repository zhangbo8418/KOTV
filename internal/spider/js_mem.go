package spider

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	qjs "github.com/buke/quickjs-go"

	"github.com/bobo/KOTV/internal/util"
)

// Module.java：LruCache(50) + http / assets:// / lib/ 取源。
const jsMemMaxEntries = 50

var (
	jsMemMu    sync.Mutex
	jsMemByKey = map[string]*jsMemEntry{}
	jsMemOrder []string // 旧→新
)

type jsMemEntry struct {
	source string
}

func clearJSMemoryCaches() {
	jsMemMu.Lock()
	jsMemByKey = map[string]*jsMemEntry{}
	jsMemOrder = nil
	jsMemMu.Unlock()
}

func jsMemGet(key string) (string, bool) {
	jsMemMu.Lock()
	defer jsMemMu.Unlock()
	e, ok := jsMemByKey[key]
	if !ok || e == nil {
		return "", false
	}
	// 命中提升到最新
	for i, k := range jsMemOrder {
		if k == key {
			jsMemOrder = append(append(jsMemOrder[:i], jsMemOrder[i+1:]...), key)
			break
		}
	}
	return e.source, true
}

func jsMemSet(key, source string) {
	jsMemMu.Lock()
	defer jsMemMu.Unlock()
	if _, ok := jsMemByKey[key]; ok {
		jsMemByKey[key] = &jsMemEntry{source: source}
		for i, k := range jsMemOrder {
			if k == key {
				jsMemOrder = append(append(jsMemOrder[:i], jsMemOrder[i+1:]...), key)
				return
			}
		}
		jsMemOrder = append(jsMemOrder, key)
		return
	}
	for len(jsMemOrder) >= jsMemMaxEntries {
		old := jsMemOrder[0]
		jsMemOrder = jsMemOrder[1:]
		delete(jsMemByKey, old)
	}
	jsMemByKey[key] = &jsMemEntry{source: source}
	jsMemOrder = append(jsMemOrder, key)
}

// assetLibs assets/js/lib/*（内存 embed，不落盘）。
func assetLibs() map[string]string {
	return map[string]string{
		"cat.js":         jsCat,
		"cheerio.min.js": jsCheerio,
		"crypto-js.js":   jsCrypto,
		"gbk.js":         jsGBK,
		"similarity.js":  jsSimilarity,
		"http.js":        jsHTTP,
		"spider.js":      jsSpiderLib,
		"parser.js":      jsParser, // KOTV 补 pdfh（TV 走 jar Function）
	}
}

func readAssetLib(name string) string {
	name = strings.TrimPrefix(name, "/")
	name = strings.TrimPrefix(name, "js/")
	name = strings.TrimPrefix(name, "lib/")
	if src, ok := assetLibs()[name]; ok {
		return src
	}
	return ""
}

// moduleFetch Module.fetch（仅内存 LruCache，无磁盘缓存）。
func moduleFetch(name string) string {
	if name == "" {
		return ""
	}
	if cached, ok := jsMemGet(name); ok && cached != "" {
		return cached
	}
	start := time.Now()
	var content string
	var via string
	switch {
	case strings.HasPrefix(name, "http://") || strings.HasPrefix(name, "https://"):
		data, err := util.HTTPGet(name, nil)
		if err != nil {
			jsLog("[js-mod] http fail name=%s err=%v", name, err)
		} else if data == "" {
			jsLog("[js-mod] http empty name=%s", name)
		} else if looksLikeNonJS(data) {
			jsLog("[js-mod] http non-js name=%s preview=%q", name, jsPreview(data, 120))
		} else {
			content = data
			via = "http"
		}
		if content == "" {
			if lib := toLibAssetPath(name); lib != "" {
				content = readAssetLib(lib)
				if content != "" {
					via = "asset-fallback:" + lib
				}
			}
		}
	case strings.HasPrefix(name, "assets://") || strings.HasPrefix(name, "assets/"):
		content = readAssetLib(strings.TrimPrefix(strings.TrimPrefix(name, "assets://"), "assets/"))
		via = "assets"
	case strings.HasPrefix(name, "lib/"):
		content = readAssetLib(name)
		via = "lib"
	case strings.HasPrefix(name, "file://"):
		b, err := os.ReadFile(strings.TrimPrefix(name, "file://"))
		if err == nil {
			content = string(b)
			via = "file"
		} else {
			jsLog("[js-mod] file fail name=%s err=%v", name, err)
		}
	default:
		if st, err := os.Stat(name); err == nil && !st.IsDir() {
			b, err := os.ReadFile(name)
			if err == nil {
				content = string(b)
				via = "path"
			}
		}
		// UriResolve 后可能变成 js/lib/X；仍回落到内置 assets
		if content == "" {
			if lib := toLibAssetPath(name); lib != "" {
				content = readAssetLib(lib)
				if content != "" {
					via = "asset-fallback:" + lib
				}
			}
		}
	}
	if content != "" {
		jsMemSet(name, content)
		jsLog("[js-mod] ok name=%s via=%s bytes=%d cost=%s", name, via, len(content), time.Since(start).Truncate(time.Millisecond))
	} else {
		jsLog("[js-mod] miss name=%s cost=%s", name, time.Since(start).Truncate(time.Millisecond))
	}
	return content
}

func toLibAssetPath(name string) string {
	if strings.HasPrefix(name, "lib/") {
		if _, ok := assetLibs()[strings.TrimPrefix(name, "lib/")]; ok {
			return name
		}
		// UriResolve 可能叠出 lib/lib/X；取已知文件名
		if base := filepath.Base(name); base != "" && base != "." {
			if _, ok := assetLibs()[base]; ok {
				return "lib/" + base
			}
		}
		return name
	}
	if strings.HasPrefix(name, "assets://js/lib/") {
		return "lib/" + strings.TrimPrefix(name, "assets://js/lib/")
	}
	if strings.HasPrefix(name, "assets/js/lib/") {
		return "lib/" + strings.TrimPrefix(name, "assets/js/lib/")
	}
	if i := strings.Index(name, "/lib/"); i >= 0 {
		rest := name[i+5:]
		if rest == "" {
			return ""
		}
		if _, ok := assetLibs()[rest]; ok {
			return "lib/" + rest
		}
		if base := filepath.Base(rest); base != "" && base != "." {
			if _, ok := assetLibs()[base]; ok {
				return "lib/" + base
			}
		}
		return "lib/" + rest
	}
	return ""
}

func looksLikeNonJS(content string) bool {
	trim := strings.TrimSpace(content)
	if trim == "" {
		return true
	}
	lower := strings.ToLower(trim)
	if strings.HasPrefix(trim, "<!") || strings.HasPrefix(trim, "<?xml") ||
		strings.HasPrefix(lower, "<html") || strings.HasPrefix(trim, "<Error") {
		return true
	}
	return strings.HasPrefix(lower, "404 ") || lower == "404" ||
		strings.HasPrefix(lower, "403 ") ||
		strings.Contains(lower, "page not found") ||
		strings.Contains(lower, "access denied")
}

// moduleNormalize UriUtil.resolve(base, name)（含 lib/ 相对解析）。
func moduleNormalize(base, name string) string {
	if name == "" {
		return base
	}
	if strings.HasPrefix(name, "node:") {
		return name
	}
	return util.UriResolve(base, name)
}

// createSpiderObj Spider.createObj：
// createFun(pdfh) → evaluateModule(api) → evaluateModule(spider.js % api)。
// 依赖由 installTVModuleLoader 按需 Module.fetch（同 TV BytecodeModuleLoader）。
func createSpiderObj(ctx *qjs.Context, api string) (isCat bool, err error) {
	content := moduleFetch(api)
	if content == "" || looksLikeNonJS(content) {
		if st, e := os.Stat(api); e == nil && !st.IsDir() {
			b, e := os.ReadFile(api)
			if e != nil {
				return false, fmt.Errorf("读取 JS api 失败: %w", e)
			}
			content = string(b)
			jsMemSet(api, content)
		}
	}
	if content == "" || looksLikeNonJS(content) {
		jsLog("[js] api empty/non-js api=%s preview=%q", api, jsPreview(content, 120))
		return false, fmt.Errorf("JS api 内容为空，请检查网络或 api 地址: %s", api)
	}

	isCat = strings.Contains(content, "__jsEvalReturn")
	content = strings.ReplaceAll(content, "__JS_SPIDER__", "globalThis.__JS_SPIDER__")
	jsLog("[js] eval api=%s cat=%v bytes=%d", api, isCat, len(content))

	// createFun：先挂 pdfh，再加载蜘蛛
	if err := ensurePDFH(ctx); err != nil {
		jsLog("[js] ensurePDFH fail: %v", err)
		return isCat, err
	}
	// evaluateModule：走 Eval(MODULE)，勿用 LoadModule 字节码 roundtrip
	//（后者在大模块上会导致后续 import 报 property is not configurable）。
	if err := evalJSModule(ctx, content, api); err != nil {
		jsLog("[js] evaluateModule api fail: %v", err)
		return isCat, fmt.Errorf("evaluateModule api: %w", err)
	}
	wrapper := fmt.Sprintf(jsSpiderLib, api)
	if err := evalJSModule(ctx, wrapper, "js/lib/spider.js"); err != nil {
		jsLog("[js] evaluateModule spider.js fail: %v", err)
		return isCat, fmt.Errorf("evaluateModule spider.js: %w", err)
	}
	return isCat, nil
}

// evalJSModule QuickJSContext.evaluateModule。
func evalJSModule(ctx *qjs.Context, code, filename string) error {
	if code == "" {
		return fmt.Errorf("空模块: %s", filename)
	}
	if !looksLikeESModule(code) {
		code = code + "\nexport default globalThis;\n"
	}
	v := ctx.Eval(code, qjs.EvalFlagModule(true), qjs.EvalFileName(filename), qjs.EvalAwait(true))
	if v == nil {
		return fmt.Errorf("Eval module 返回空: %s", filename)
	}
	defer v.Free()
	if v.IsException() {
		return fmt.Errorf("%s: %w", filename, ctx.Exception())
	}
	return nil
}

func ensurePDFH(ctx *qjs.Context) error {
	pdfh := ctx.Globals().Get("pdfh")
	ok := pdfh != nil && !pdfh.IsUndefined() && pdfh.IsFunction()
	if pdfh != nil {
		pdfh.Free()
	}
	if ok || jsParser == "" {
		return nil
	}
	// parser.js 会 import cheerio；由 ModuleLoader 按需拉取。
	// 文件名勿放在 js/lib/ 下，否则 UriResolve(base,"lib/parser.js") 会叠成 js/lib/lib/...
	boot := `import "lib/parser.js";`
	if err := evalJSModule(ctx, boot, "_pdfh_boot.js"); err != nil {
		return fmt.Errorf("注入 pdfh 失败: %w", err)
	}
	if jsGBK != "" {
		gbkBoot := `import { gbkTool } from "lib/gbk.js"; globalThis.gbkTool = gbkTool;`
		_ = evalJSModule(ctx, gbkBoot, "_gbk_boot.js")
	}
	return nil
}
