#include "bridge.h"
#include <jni.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#if defined(_WIN32)
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
typedef HMODULE kotv_lib_t;
static kotv_lib_t kotv_dlopen(const char *path) {
	int n;
	wchar_t *w;
	HMODULE h;
	if (!path || !path[0])
		return NULL;
	n = MultiByteToWideChar(CP_UTF8, 0, path, -1, NULL, 0);
	if (n <= 0)
		return NULL;
	w = (wchar_t *)malloc((size_t)n * sizeof(wchar_t));
	if (!w)
		return NULL;
	MultiByteToWideChar(CP_UTF8, 0, path, -1, w, n);
	h = LoadLibraryW(w);
	free(w);
	return h;
}
#define kotv_dlsym GetProcAddress
#define kotv_dlclose FreeLibrary
#else
#include <dlfcn.h>
typedef void *kotv_lib_t;
#define kotv_dlopen(path) dlopen(path, RTLD_NOW | RTLD_LOCAL)
#define kotv_dlsym dlsym
#define kotv_dlclose dlclose
#endif

typedef jint (*JNI_CreateJavaVM_t)(JavaVM **pvm, JNIEnv **penv, void *args);

static kotv_lib_t g_jvm_lib;
static JavaVM *g_vm;
static JNIEnv *g_env;

static void write_err(char *errbuf, int errbuf_len, const char *msg) {
	if (!errbuf || errbuf_len <= 0)
		return;
	snprintf(errbuf, (size_t)errbuf_len, "%s", msg ? msg : "unknown");
}

int kotv_jvm_ready(void) { return g_vm != NULL ? 1 : 0; }

void kotv_jvm_shutdown(void) {
	if (g_vm) {
		(*g_vm)->DestroyJavaVM(g_vm);
	}
	g_vm = NULL;
	g_env = NULL;
	if (g_jvm_lib) {
		kotv_dlclose(g_jvm_lib);
		g_jvm_lib = NULL;
	}
}

int kotv_jvm_start(const char *jvm_lib, const char *bridge_jar, const char *cache_dir, int proxy_port, char *errbuf, int errbuf_len) {
	if (g_vm)
		return 0;
	if (!jvm_lib || !bridge_jar) {
		write_err(errbuf, errbuf_len, "jvm_lib or bridge_jar missing");
		return -1;
	}

	g_jvm_lib = kotv_dlopen(jvm_lib);
	if (!g_jvm_lib) {
		write_err(errbuf, errbuf_len, "dlopen libjvm failed");
		return -2;
	}

	JNI_CreateJavaVM_t create = (JNI_CreateJavaVM_t)kotv_dlsym(g_jvm_lib, "JNI_CreateJavaVM");
	if (!create) {
		write_err(errbuf, errbuf_len, "JNI_CreateJavaVM symbol missing");
		kotv_dlclose(g_jvm_lib);
		g_jvm_lib = NULL;
		return -3;
	}

	char cp[4096];
	char cache[1024];
	char proxy[128];
	snprintf(cp, sizeof(cp), "-Djava.class.path=%s", bridge_jar);
	snprintf(cache, sizeof(cache), "-Dkotv.cache.dir=%s", cache_dir ? cache_dir : ".");
	snprintf(proxy, sizeof(proxy), "-Dkotv.proxy.port=%d", proxy_port);

	JavaVMOption opts[16];
	int n = 0;
	opts[n++].optionString = strdup("-Djava.awt.headless=true");
	opts[n++].optionString = strdup(cp);
	opts[n++].optionString = strdup(cache);
	opts[n++].optionString = strdup(proxy);
	opts[n++].optionString = strdup("-Djava.net.useSystemProxies=false");
	opts[n++].optionString = strdup("-Dfile.encoding=UTF-8");
	opts[n++].optionString = strdup("--add-opens=java.base/java.lang=ALL-UNNAMED");
	opts[n++].optionString = strdup("--add-opens=java.base/java.util=ALL-UNNAMED");

	JavaVMInitArgs args;
	memset(&args, 0, sizeof(args));
	args.version = JNI_VERSION_10;
	args.nOptions = n;
	args.options = opts;
	args.ignoreUnrecognized = JNI_TRUE;

	JavaVM *vm = NULL;
	JNIEnv *env = NULL;
	jint rc = create(&vm, &env, &args);
	for (int i = 0; i < n; i++)
		free(opts[i].optionString);

	if (rc != 0 || !vm || !env) {
		write_err(errbuf, errbuf_len, "JNI_CreateJavaVM failed");
		kotv_dlclose(g_jvm_lib);
		g_jvm_lib = NULL;
		return -4;
	}
	g_vm = vm;
	g_env = env;
	return 0;
}

int kotv_jvm_call(const char *json_in, char *json_out, int json_out_len, char *errbuf, int errbuf_len) {
	if (!g_vm || !g_env || !json_in || !json_out || json_out_len <= 1) {
		write_err(errbuf, errbuf_len, "jvm not started");
		return -1;
	}

	JNIEnv *env = g_env;
	jclass cls = (*env)->FindClass(env, "com/bobo/kotv/bridge/SpiderBridge");
	if (!cls) {
		write_err(errbuf, errbuf_len, "SpiderBridge class not found");
		return -2;
	}
	jmethodID mid = (*env)->GetStaticMethodID(env, cls, "call", "(Ljava/lang/String;)Ljava/lang/String;");
	if (!mid) {
		(*env)->DeleteLocalRef(env, cls);
		write_err(errbuf, errbuf_len, "SpiderBridge.call missing");
		return -3;
	}
	jstring jstr = (*env)->NewStringUTF(env, json_in);
	if (!jstr) {
		(*env)->DeleteLocalRef(env, cls);
		write_err(errbuf, errbuf_len, "NewStringUTF failed");
		return -4;
	}
	jstring jret = (jstring)(*env)->CallStaticObjectMethod(env, cls, mid, jstr);
	(*env)->DeleteLocalRef(env, jstr);
	(*env)->DeleteLocalRef(env, cls);
	if ((*env)->ExceptionCheck(env)) {
		(*env)->ExceptionClear(env);
		write_err(errbuf, errbuf_len, "Java exception in SpiderBridge.call");
		return -5;
	}
	if (!jret) {
		write_err(errbuf, errbuf_len, "null return from SpiderBridge.call");
		return -6;
	}
	const char *utf = (*env)->GetStringUTFChars(env, jret, NULL);
	if (!utf) {
		(*env)->DeleteLocalRef(env, jret);
		write_err(errbuf, errbuf_len, "GetStringUTFChars failed");
		return -7;
	}
	snprintf(json_out, (size_t)json_out_len, "%s", utf);
	(*env)->ReleaseStringUTFChars(env, jret, utf);
	(*env)->DeleteLocalRef(env, jret);
	return 0;
}
