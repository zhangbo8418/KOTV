//go:build cgo

package embed

// Available 页内 VLC 已移除。
func Available() bool { return false }
