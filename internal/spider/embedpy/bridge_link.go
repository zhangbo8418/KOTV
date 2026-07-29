//go:build cgo && !kotv_android

package embedpy

// 仅链接 native/bridge.c；API 声明在 py.go。

/*
#cgo CFLAGS: -I${SRCDIR}/native
#include "native/bridge.c"
*/
import "C"
