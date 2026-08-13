package spider

/*
#cgo CFLAGS: -I${SRCDIR}/qjsinc/quickjs -I${SRCDIR}/qjsinc
#include "bridge.h"

extern char *kotvModuleNormalize(JSContext *ctx, const char *base_name, const char *name, void *opaque);
extern JSModuleDef *kotvModuleLoader(JSContext *ctx, const char *module_name, void *opaque);
extern void kotv_throw_module_error(JSContext *ctx, const char *msg);
*/
import "C"
import (
	"reflect"
	"unsafe"

	qjs "github.com/buke/quickjs-go"
)

//go:generate go run gen_qjsinc.go

// installTVModuleLoader BytecodeModuleLoader：
// normalize = moduleNormalize；load = Module.fetch + compile-only（运行时按需）。
func installTVModuleLoader(rt *qjs.Runtime) {
	if rt == nil {
		return
	}
	cref := runtimeCRef(rt)
	if cref == nil {
		return
	}
	C.JS_SetModuleLoaderFunc(cref,
		(*C.JSModuleNormalizeFunc)(C.kotvModuleNormalize),
		(*C.JSModuleLoaderFunc)(C.kotvModuleLoader),
		nil)
}

func runtimeCRef(rt *qjs.Runtime) *C.JSRuntime {
	v := reflect.ValueOf(rt).Elem().FieldByName("ref")
	if !v.IsValid() || v.Kind() != reflect.Pointer {
		return nil
	}
	return (*C.JSRuntime)(unsafe.Pointer(v.UnsafePointer()))
}
