package goproxy

// StartSidecar 启动社区 jar 依赖的 go 多线程 sidecar（监听 :7777）。
// 潇洒哥等仓 ProxyVideo.go() 会先 GET http://127.0.0.1:{proxyPort}/go 触发本函数。
// 对齐 TV 升级 SDK 前 Nano /go → Go.start()。
func StartSidecar() error {
	return startSidecarPlatform()
}
