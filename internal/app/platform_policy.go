package app

import "runtime"

// iOS 端不提供本地爬虫能力（JS/PY/站点抓取）；仅保留前端展示与播放链路。
func localCrawlerDisabled() bool {
	return runtime.GOOS == "ios"
}
