#include "bridge.h"
#include <jni.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#if defined(_WIN32)
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#ifndef LOAD_WITH_ALTERED_SEARCH_PATH
#define LOAD_WITH_ALTERED_SEARCH_PATH 0x00000008
#endif
typedef HMODULE kotv_lib_t;
static DWORD g_kotv_dl_err;

static kotv_lib_t kotv_dlopen(const char *path) {
	int n;
	wchar_t *w = NULL;
	wchar_t *dir = NULL;
	HMODULE h = NULL;
	g_kotv_dl_err = 0;
	if (!path || !path[0])
		return NULL;
	n = MultiByteToWideChar(CP_UTF8, 0, path, -1, NULL, 0);
	if (n <= 0) {
		g_kotv_dl_err = GetLastError();
		return NULL;
	}
	w = (wchar_t *)malloc((size_t)n * sizeof(wchar_t));
	if (!w)
		return NULL;
	MultiByteToWideChar(CP_UTF8, 0, path, -1, w, n);

	/* jvm.dll 在 bin\server，依赖 java.dll 等在 bin：把 bin 设为 DLL 目录并前置 PATH。 */
	dir = (wchar_t *)malloc((size_t)n * sizeof(wchar_t));
	if (dir) {
		wchar_t *slash;
		memcpy(dir, w, (size_t)n * sizeof(wchar_t));
		slash = wcsrchr(dir, L'\\');
		if (!slash)
			slash = wcsrchr(dir, L'/');
		if (slash) {
			*slash = L'\0'; /* ...\bin\server */
			slash = wcsrchr(dir, L'\\');
			if (!slash)
				slash = wcsrchr(dir, L'/');
			if (slash) {
				*slash = L'\0'; /* ...\bin */
				SetDllDirectoryW(dir);
				{
					wchar_t pathenv[32768];
					DWORD plen = GetEnvironmentVariableW(L"PATH", pathenv, 32768);
					if (plen > 0 && plen < 32000) {
						size_t dlen = wcslen(dir);
						if (dlen + 1 + plen + 1 < 32768) {
							wchar_t *merged = (wchar_t *)malloc((dlen + 1 + plen + 1) * sizeof(wchar_t));
							if (merged) {
								memcpy(merged, dir, dlen * sizeof(wchar_t));
								merged[dlen] = L';';
								memcpy(merged + dlen + 1, pathenv, (plen + 1) * sizeof(wchar_t));
								SetEnvironmentVariableW(L"PATH", merged);
								free(merged);
							}
						}
					} else {
						SetEnvironmentVariableW(L"PATH", dir);
					}
				}
			}
		}
	}

	h = LoadLibraryExW(w, NULL, LOAD_WITH_ALTERED_SEARCH_PATH);
	if (!h)
		h = LoadLibraryW(w);
	if (!h)
		g_kotv_dl_err = GetLastError();
	free(dir);
	free(w);
	return h;
}

static unsigned long kotv_dlopen_last_error(void) {
	return (unsigned long)g_kotv_dl_err;
}
#define kotv_dlsym GetProcAddress
#define kotv_dlclose FreeLibrary
#else
#include <dlfcn.h>
typedef void *kotv_lib_t;
#define kotv_dlopen(path) dlopen(path, RTLD_NOW | RTLD_LOCAL)
static unsigned long kotv_dlopen_last_error(void) { return 0; }
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
#if defined(_WIN32)
		char msg[160];
		snprintf(msg, sizeof(msg), "dlopen libjvm failed (GetLastError=%lu)", kotv_dlopen_last_error());
		write_err(errbuf, errbuf_len, msg);
#else
		write_err(errbuf, errbuf_len, "dlopen libjvm failed");
#endif
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
	char java_home_opt[1100];
	/* .../jre/bin/server/jvm.dll → java.home=.../jre */
	{
		char home[1024];
		const char *p = jvm_lib;
		size_t len = strlen(p);
		if (len >= sizeof(home))
			len = sizeof(home) - 1;
		memcpy(home, p, len);
		home[len] = 0;
		for (int i = 0; i < 3; i++) {
			char *slash = strrchr(home, '/');
			char *bslash = strrchr(home, '\\');
			char *cut = slash;
			if (bslash && (!cut || bslash > cut))
				cut = bslash;
			if (!cut)
				break;
			*cut = 0;
		}
		if (home[0])
			snprintf(java_home_opt, sizeof(java_home_opt), "-Djava.home=%s", home);
		else
			java_home_opt[0] = 0;
	}
	snprintf(cp, sizeof(cp), "-Djava.class.path=%s", bridge_jar);
	snprintf(cache, sizeof(cache), "-Dkotv.cache.dir=%s", cache_dir ? cache_dir : ".");
	snprintf(proxy, sizeof(proxy), "-Dkotv.proxy.port=%d", proxy_port);

	JavaVMOption opts[16];
	int n = 0;
	opts[n++].optionString = strdup("-Djava.awt.headless=true");
	if (java_home_opt[0])
		opts[n++].optionString = strdup(java_home_opt);
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
		char msg[96];
		snprintf(msg, sizeof(msg), "JNI_CreateJavaVM failed (rc=%d)", (int)rc);
		write_err(errbuf, errbuf_len, msg);
		kotv_dlclose(g_jvm_lib);
		g_jvm_lib = NULL;
		return -4;
	}
	g_vm = vm;
	g_env = env;
	return 0;
}

static JNIEnv *jvm_env_for_call(int *attached) {
	*attached = 0;
	if (!g_vm)
		return NULL;
	JNIEnv *env = NULL;
	jint st = (*g_vm)->GetEnv(g_vm, (void **)&env, JNI_VERSION_10);
	if (st == JNI_OK && env)
		return env;
	if (st == JNI_EDETACHED) {
		if ((*g_vm)->AttachCurrentThread(g_vm, (void **)&env, NULL) != 0)
			return NULL;
		*attached = 1;
		return env;
	}
	/* 创建线程留下的 g_env 仅作回落；正确用法是 Go 侧 LockOSThread 专用 worker。 */
	return g_env;
}

int kotv_jvm_call(const char *json_in, char *json_out, int json_out_len, char *errbuf, int errbuf_len) {
	if (!g_vm || !json_in || !json_out || json_out_len <= 1) {
		write_err(errbuf, errbuf_len, "jvm not started");
		return -1;
	}

	int attached = 0;
	JNIEnv *env = jvm_env_for_call(&attached);
	if (!env) {
		write_err(errbuf, errbuf_len, "JNIEnv unavailable");
		return -1;
	}
	jclass cls = (*env)->FindClass(env, "com/bobo/kotv/bridge/SpiderBridge");
	if (!cls) {
		if (attached)
			(*g_vm)->DetachCurrentThread(g_vm);
		write_err(errbuf, errbuf_len, "SpiderBridge class not found");
		return -2;
	}
	jmethodID mid = (*env)->GetStaticMethodID(env, cls, "call", "(Ljava/lang/String;)Ljava/lang/String;");
	if (!mid) {
		(*env)->DeleteLocalRef(env, cls);
		if (attached)
			(*g_vm)->DetachCurrentThread(g_vm);
		write_err(errbuf, errbuf_len, "SpiderBridge.call missing");
		return -3;
	}
	jstring jstr = (*env)->NewStringUTF(env, json_in);
	if (!jstr) {
		(*env)->DeleteLocalRef(env, cls);
		if (attached)
			(*g_vm)->DetachCurrentThread(g_vm);
		write_err(errbuf, errbuf_len, "NewStringUTF failed");
		return -4;
	}
	jstring jret = (jstring)(*env)->CallStaticObjectMethod(env, cls, mid, jstr);
	(*env)->DeleteLocalRef(env, jstr);
	(*env)->DeleteLocalRef(env, cls);
	if ((*env)->ExceptionCheck(env)) {
		(*env)->ExceptionClear(env);
		if (attached)
			(*g_vm)->DetachCurrentThread(g_vm);
		write_err(errbuf, errbuf_len, "Java exception in SpiderBridge.call");
		return -5;
	}
	if (!jret) {
		if (attached)
			(*g_vm)->DetachCurrentThread(g_vm);
		write_err(errbuf, errbuf_len, "null return from SpiderBridge.call");
		return -6;
	}
	const char *utf = (*env)->GetStringUTFChars(env, jret, NULL);
	if (!utf) {
		(*env)->DeleteLocalRef(env, jret);
		if (attached)
			(*g_vm)->DetachCurrentThread(g_vm);
		write_err(errbuf, errbuf_len, "GetStringUTFChars failed");
		return -7;
	}
	snprintf(json_out, (size_t)json_out_len, "%s", utf);
	(*env)->ReleaseStringUTFChars(env, jret, utf);
	(*env)->DeleteLocalRef(env, jret);
	if (attached)
		(*g_vm)->DetachCurrentThread(g_vm);
	return 0;
}

int kotv_jvm_cancel_all(char *errbuf, int errbuf_len) {
	if (!g_vm) {
		write_err(errbuf, errbuf_len, "jvm not started");
		return -1;
	}
	int attached = 0;
	JNIEnv *env = jvm_env_for_call(&attached);
	if (!env) {
		write_err(errbuf, errbuf_len, "JNIEnv unavailable");
		return -1;
	}
	jclass cls = (*env)->FindClass(env, "com/bobo/kotv/bridge/SpiderBridge");
	if (!cls) {
		if (attached)
			(*g_vm)->DetachCurrentThread(g_vm);
		write_err(errbuf, errbuf_len, "SpiderBridge class not found");
		return -2;
	}
	jmethodID mid = (*env)->GetStaticMethodID(env, cls, "call", "(Ljava/lang/String;)Ljava/lang/String;");
	if (!mid) {
		(*env)->DeleteLocalRef(env, cls);
		if (attached)
			(*g_vm)->DetachCurrentThread(g_vm);
		write_err(errbuf, errbuf_len, "SpiderBridge.call missing");
		return -3;
	}
	jstring jstr = (*env)->NewStringUTF(env, "{\"method\":\"cancelAll\"}");
	if (!jstr) {
		(*env)->DeleteLocalRef(env, cls);
		if (attached)
			(*g_vm)->DetachCurrentThread(g_vm);
		write_err(errbuf, errbuf_len, "NewStringUTF failed");
		return -4;
	}
	jstring jret = (jstring)(*env)->CallStaticObjectMethod(env, cls, mid, jstr);
	(*env)->DeleteLocalRef(env, jstr);
	(*env)->DeleteLocalRef(env, cls);
	if (jret)
		(*env)->DeleteLocalRef(env, jret);
	if ((*env)->ExceptionCheck(env)) {
		(*env)->ExceptionClear(env);
		if (attached)
			(*g_vm)->DetachCurrentThread(g_vm);
		write_err(errbuf, errbuf_len, "Java exception in cancelAll");
		return -5;
	}
	if (attached)
		(*g_vm)->DetachCurrentThread(g_vm);
	return 0;
}
