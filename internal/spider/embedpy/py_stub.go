//go:build !cgo || kotv_android

package embedpy

import "fmt"

func StartSession(runner, script, key, ext, api, cache string) (uintptr, error) {
	return 0, fmt.Errorf("embed Python unavailable")
}
func CallSession(uintptr, string) (string, error) {
	return "", fmt.Errorf("embed Python unavailable")
}
func StopSession(uintptr) {}
func Shutdown()           {}
func DefaultCache() string { return "" }
