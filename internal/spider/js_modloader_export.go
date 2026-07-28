package spider

/*
#cgo CFLAGS: -I${SRCDIR}/qjsinc/quickjs -I${SRCDIR}/qjsinc
#include "bridge.h"
#include <stdlib.h>

extern void kotv_throw_module_error(JSContext *ctx, const char *msg);
*/
import "C"
import (
	"fmt"
	"strings"
	"unsafe"
)

//export kotvModuleNormalize
func kotvModuleNormalize(ctx *C.JSContext, base, name *C.char, opaque unsafe.Pointer) *C.char {
	_ = opaque
	resolved := moduleNormalize(C.GoString(base), C.GoString(name))
	if resolved == "" {
		resolved = C.GoString(name)
	}
	tmp := C.CString(resolved)
	defer C.free(unsafe.Pointer(tmp))
	return C.js_strdup(ctx, tmp)
}

//export kotvModuleLoader
func kotvModuleLoader(ctx *C.JSContext, moduleName *C.char, opaque unsafe.Pointer) *C.JSModuleDef {
	_ = opaque
	name := C.GoString(moduleName)
	if name == "" || strings.HasPrefix(name, "node:") {
		throwModuleLoadError(ctx, name)
		return nil
	}
	if lib := toLibAssetPath(name); lib == "lib/spider.js" {
		throwModuleLoadError(ctx, name)
		return nil
	}
	code := moduleCodeForLoader(name)
	if code == "" {
		throwModuleLoadError(ctx, name)
		return nil
	}
	if !looksLikeESModule(code) {
		code = code + "\nexport default globalThis;\n"
	}
	ccode := C.CString(code)
	defer C.free(unsafe.Pointer(ccode))
	val := C.JS_Eval(ctx, ccode, C.size_t(len(code)), moduleName,
		C.int(C.JS_EVAL_TYPE_MODULE|C.JS_EVAL_FLAG_COMPILE_ONLY))
	if bool(C.JS_IsException(val)) {
		return nil
	}
	if C.js_module_set_import_meta(ctx, val, false, false) < 0 {
		C.JS_FreeValue(ctx, val)
		return nil
	}
	m := (*C.JSModuleDef)(C.JS_VALUE_GET_PTR_Wrapper(val))
	C.JS_FreeValue(ctx, val)
	return m
}

func moduleCodeForLoader(name string) string {
	if lib := toLibAssetPath(name); lib != "" {
		switch strings.TrimPrefix(lib, "lib/") {
		case "crypto-js.js":
			return "export default globalThis.CryptoJS || globalThis;\n"
		case "http.js":
			return "export default globalThis.http || globalThis;\n"
		case "spider.js":
			return ""
		}
		if src := readAssetLib(lib); src != "" {
			return src
		}
	}
	return moduleFetch(name)
}

func throwModuleLoadError(ctx *C.JSContext, name string) {
	msg := C.CString(fmt.Sprintf("could not load module '%s'", name))
	defer C.free(unsafe.Pointer(msg))
	C.kotv_throw_module_error(ctx, msg)
}
