//go:build !cgo || kotv_android

package embedjvm

import "fmt"

func EnsureStarted(string) error { return fmt.Errorf("embed JVM unavailable") }
func Call([]byte) (string, error) {
	return "", fmt.Errorf("embed JVM unavailable")
}
func Shutdown()     {}
func Interrupt()    {}
func Started() bool { return false }

var ErrInterrupted = fmt.Errorf("JAR 调用已中断")
