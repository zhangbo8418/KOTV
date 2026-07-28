#include "bridge.h"

void kotv_throw_module_error(JSContext *ctx, const char *msg) {
	JS_ThrowReferenceError(ctx, "%s", msg);
}
