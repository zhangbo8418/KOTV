package spider

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"

	qjs "github.com/buke/quickjs-go"

	"github.com/bobo/KOTV/internal/util"
)

// 对齐 TV Module.java：LruCache(50) + http / assets:// / lib/ 取源。
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

// assetLibs 对齐 TV assets/js/lib/*（内存 embed，不落盘）。
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

// moduleFetch 对齐 TV Module.fetch。
func moduleFetch(name string) string {
	if name == "" {
		return ""
	}
	if cached, ok := jsMemGet(name); ok && cached != "" {
		return cached
	}
	var content string
	switch {
	case strings.HasPrefix(name, "http://") || strings.HasPrefix(name, "https://"):
		data, err := util.HTTPGet(name, nil)
		if err == nil && data != "" && !looksLikeNonJS(data) {
			content = data
		} else if lib := toLibAssetPath(name); lib != "" {
			content = readAssetLib(lib)
		}
	case strings.HasPrefix(name, "assets://") || strings.HasPrefix(name, "assets/"):
		content = readAssetLib(strings.TrimPrefix(strings.TrimPrefix(name, "assets://"), "assets/"))
	case strings.HasPrefix(name, "lib/"):
		content = readAssetLib(name)
	case strings.HasPrefix(name, "file://"):
		b, err := os.ReadFile(strings.TrimPrefix(name, "file://"))
		if err == nil {
			content = string(b)
		}
	default:
		if st, err := os.Stat(name); err == nil && !st.IsDir() {
			b, err := os.ReadFile(name)
			if err == nil {
				content = string(b)
			}
		}
		// UriResolve 后可能变成 js/lib/X；仍回落到内置 assets
		if content == "" {
			if lib := toLibAssetPath(name); lib != "" {
				content = readAssetLib(lib)
			}
		}
	}
	if content != "" {
		jsMemSet(name, content)
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

// moduleNormalize 对齐 TV UriUtil.resolve(base, name)（含 lib/ 相对解析）。
func moduleNormalize(base, name string) string {
	if name == "" {
		return base
	}
	if strings.HasPrefix(name, "node:") {
		return name
	}
	return util.UriResolve(base, name)
}

// createSpiderObj 对齐 TV Spider.createObj：
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
		return false, fmt.Errorf("JS api 内容为空，请检查网络或 api 地址: %s", api)
	}

	isCat = strings.Contains(content, "__jsEvalReturn")
	content = strings.ReplaceAll(content, "__JS_SPIDER__", "globalThis.__JS_SPIDER__")

	// 对齐 TV createFun：先挂 pdfh，再加载蜘蛛
	if err := ensurePDFH(ctx); err != nil {
		return isCat, err
	}
	// 对齐 TV evaluateModule：走 Eval(MODULE)，勿用 LoadModule 字节码 roundtrip
	//（后者在大模块上会导致后续 import 报 property is not configurable）。
	if err := evalJSModule(ctx, content, api); err != nil {
		return isCat, fmt.Errorf("evaluateModule api: %w", err)
	}
	wrapper := fmt.Sprintf(jsSpiderLib, api)
	if err := evalJSModule(ctx, wrapper, "js/lib/spider.js"); err != nil {
		return isCat, fmt.Errorf("evaluateModule spider.js: %w", err)
	}
	return isCat, nil
}

// evalJSModule 对齐 TV QuickJSContext.evaluateModule。
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
