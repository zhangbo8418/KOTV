//go:build cgo

package embed

// Available 当前无 Go 侧页内嵌入引擎。
func Available() bool { return false }
