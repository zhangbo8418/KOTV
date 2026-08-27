package spider

import (
	"os"
	"strings"

	"github.com/bobo/KOTV/internal/paths"
)

// ProxyBodyFileHeader 是内部标记头：当代理响应体被 bridge 溢写到磁盘文件时，
// 通过该头把文件路径传给 HTTP 层做流式回写，服务端写响应前会剥离它。
const ProxyBodyFileHeader = "X-KOTV-Body-File"

// ProxyBodyStreamHeader 是内部标记头：bridge 在 127.0.0.1 上开 TCP 泵流，
// 值为 "host:port"。Go 拨号后边读边写给客户端，避免整段视频溢写磁盘。
const ProxyBodyStreamHeader = "X-KOTV-Body-Stream"

// Spider CatVod 爬虫接口。
type Spider interface {
	Init(extend string) error
	HomeContent(filter bool) (string, error)
	HomeVideoContent() (string, error)
	CategoryContent(tid, pg string, filter bool, extend map[string]string) (string, error)
	DetailContent(ids []string) (string, error)
	SearchContent(key string, quick bool, pg string) (string, error)
	PlayerContent(flag, id string, vipFlags []string) (string, error)
	LiveContent(url string) (string, error)
	Proxy(params map[string]string) (status int, contentType string, body []byte, headers map[string]string, err error)
	Action(action string) (string, error)
	ManualVideoCheck() (bool, error)
	IsVideoFormat(url string) (bool, error)
	Destroy()
}

type noopSpider struct{}

func (noopSpider) Init(string) error                 { return nil }
func (noopSpider) HomeContent(bool) (string, error)  { return "{}", nil }
func (noopSpider) HomeVideoContent() (string, error) { return "{}", nil }
func (noopSpider) CategoryContent(string, string, bool, map[string]string) (string, error) {
	return "{}", nil
}
func (noopSpider) DetailContent([]string) (string, error)                 { return "{}", nil }
func (noopSpider) SearchContent(string, bool, string) (string, error)     { return "{}", nil }
func (noopSpider) PlayerContent(string, string, []string) (string, error) { return "{}", nil }
func (noopSpider) LiveContent(string) (string, error)                     { return "", nil }
func (noopSpider) Proxy(map[string]string) (int, string, []byte, map[string]string, error) {
	return 0, "", nil, nil, nil
}
func (noopSpider) Action(string) (string, error)      { return "", nil }
func (noopSpider) ManualVideoCheck() (bool, error)    { return false, nil }
func (noopSpider) IsVideoFormat(string) (bool, error) { return false, nil }
func (noopSpider) Destroy()                           {}

func isJS(api string) bool  { return strings.Contains(api, ".js") }
func isPy(api string) bool  { return strings.Contains(api, ".py") }
func isCSP(api string) bool { return strings.HasPrefix(api, "csp_") }

// Get 根据站源类型获取爬虫实例。
func Get(key, api, ext, jar string) Spider {
	switch {
	case isPy(api):
		return newPySpider(key, api, ext, jar)
	case isJS(api):
		return newJsSpider(key, api, ext, jar)
	case isCSP(api):
		return newJarSpider(key, api, ext, jar)
	default:
		return noopSpider{}
	}
}

// SetRecent 每次选中站点时更新 recent，供全局 proxy 使用。
func SetRecent(key, api, ext, jar string) {
	switch {
	case isPy(api):
		setRecentPy(key, api, ext, jar)
	case isJS(api):
		setRecentJs(key, api, ext, jar)
	case isCSP(api):
		setRecentJar(jar)
	}
}

func Clear() {
	clearJar()
	clearJsPy()
	clearScriptCaches()
}

// ResetScriptSpiders 换源时销毁 JS/Python 爬虫，避免旧进程状态污染新站。
func ResetScriptSpiders() {
	clearJsPy()
}

// clearScriptCaches 清空 JS 内存缓存，并清理本地 js/py 目录（含历史落盘残留）。
func clearScriptCaches() {
	clearJSMemoryCaches()
	for _, dir := range []string{paths.JsCache(), paths.PyCache()} {
		_ = os.RemoveAll(dir)
		_ = os.MkdirAll(dir, 0o755)
	}
}

// ClearJarDisk 清空 JAR 内存/bridge，并删除 Go 侧 jar 落盘（供设置页清理缓存）。
func ClearJarDisk() {
	clearJar()
}
