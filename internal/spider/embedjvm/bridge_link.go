//go:build cgo && !kotv_android

package embedjvm

// 仅负责把 native/bridge.c 编进包；API 声明在 jvm.go。

/*
#cgo CFLAGS: -I${SRCDIR}/native -I${SRCDIR}/jni
#cgo darwin CFLAGS: -I${SRCDIR}/jni/darwin
#cgo linux CFLAGS: -I${SRCDIR}/jni/linux
#cgo windows CFLAGS: -I${SRCDIR}/jni/win32
#include "native/bridge.c"
*/
import "C"
