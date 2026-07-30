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

#if defined(_WIN32)
/* Go 传入 UTF-8；HotSpot -D 选项在中文 Win 上按 ACP(GBK) 解析路径。 */
static int utf8_to_acp(const char *utf8, char *out, int out_len) {
	int wlen, alen;
	wchar_t *w;
	if (!utf8 || !out || out_len <= 0)
		return -1;
	wlen = MultiByteToWideChar(CP_UTF8, 0, utf8, -1, NULL, 0);
	if (wlen <= 0)
		return -1;
	w = (wchar_t *)malloc((size_t)wlen * sizeof(wchar_t));
	if (!w)
		return -1;
	MultiByteToWideChar(CP_UTF8, 0, utf8, -1, w, wlen);
	alen = WideCharToMultiByte(CP_ACP, 0, w, -1, out, out_len, NULL, NULL);
	free(w);
	return alen > 0 ? 0 : -1;
}

/*
 * Windows：专用 JVM 原生线程（CreateJavaVM + 全部 JNI 调用）。
 * HotSpot 在初始化与类加载时会用 SEH 探测异常；若在 Go 线程上 Attach 后调 JNI，
 * Go VEH 仍会干扰（golang/go#58542），表现为闪退或长时间无响应。
 */
typedef enum {
	KOTV_JVM_JOB_NONE = 0,
	KOTV_JVM_JOB_CALL,
	KOTV_JVM_JOB_CANCEL,
	KOTV_JVM_JOB_SHUTDOWN,
} kotv_jvm_job_kind;

typedef struct {
	kotv_jvm_job_kind kind;
	const char *json_in;
	char *json_out;
	int json_out_len;
	char *errbuf;
	int errbuf_len;
	int rc;
	HANDLE done;
} kotv_jvm_job;

static HANDLE g_jvm_owner;
static HANDLE g_jvm_job_posted;
static HANDLE g_jvm_job_done;
static CRITICAL_SECTION g_jvm_job_lock;
static kotv_jvm_job g_jvm_job;
static JavaVMInitArgs *g_boot_args;
static JNI_CreateJavaVM_t g_boot_create;
static HANDLE g_boot_done;
static volatile jint g_boot_rc;

static int kotv_jvm_call_with_env(JNIEnv *env, const char *json_in, char *json_out, int json_out_len, char *errbuf, int errbuf_len);
static int kotv_jvm_cancel_all_with_env(JNIEnv *env, char *errbuf, int errbuf_len);
static int kotv_jvm_cancel_async(char *errbuf, int errbuf_len);

static DWORD WINAPI kotv_jvm_owner_thread(LPVOID arg) {
	JavaVM *vm = NULL;
	JNIEnv *env = NULL;
	(void)arg;

	g_boot_rc = g_boot_create(&vm, &env, g_boot_args);
	if (g_boot_rc == 0 && vm && env) {
		g_vm = vm;
		g_env = env;
	}
	if (g_boot_done)
		SetEvent(g_boot_done);

	if (!g_vm || !g_env)
		return 1;

	for (;;) {
		if (WaitForSingleObject(g_jvm_job_posted, INFINITE) != WAIT_OBJECT_0)
			break;
		ResetEvent(g_jvm_job_posted);

		EnterCriticalSection(&g_jvm_job_lock);
		kotv_jvm_job job = g_jvm_job;
		LeaveCriticalSection(&g_jvm_job_lock);

		switch (job.kind) {
		case KOTV_JVM_JOB_CALL:
			job.rc = kotv_jvm_call_with_env(g_env, job.json_in, job.json_out, job.json_out_len, job.errbuf, job.errbuf_len);
			break;
		case KOTV_JVM_JOB_CANCEL:
			job.rc = kotv_jvm_cancel_all_with_env(g_env, job.errbuf, job.errbuf_len);
			break;
		case KOTV_JVM_JOB_SHUTDOWN:
			(*g_vm)->DestroyJavaVM(g_vm);
			g_vm = NULL;
			g_env = NULL;
			if (job.done)
				SetEvent(job.done);
			return 0;
		default:
			if (job.errbuf && job.errbuf_len > 0)
				write_err(job.errbuf, job.errbuf_len, "unknown jvm job");
			job.rc = -1;
			break;
		}

		EnterCriticalSection(&g_jvm_job_lock);
		g_jvm_job.rc = job.rc;
		LeaveCriticalSection(&g_jvm_job_lock);
		if (job.done)
			SetEvent(job.done);
	}
	return 0;
}

static int kotv_jvm_owner_start(JNI_CreateJavaVM_t create, JavaVMInitArgs *args) {
	DWORD tid;

	if (g_jvm_owner)
		return (int)g_boot_rc;

	InitializeCriticalSection(&g_jvm_job_lock);
	g_jvm_job_posted = CreateEventW(NULL, TRUE, FALSE, NULL);
	g_jvm_job_done = CreateEventW(NULL, TRUE, FALSE, NULL);
	g_boot_done = CreateEventW(NULL, TRUE, FALSE, NULL);
	if (!g_jvm_job_posted || !g_jvm_job_done || !g_boot_done)
		return JNI_ERR;

	g_boot_create = create;
	g_boot_args = args;
	g_boot_rc = JNI_ERR;

	g_jvm_owner = CreateThread(NULL, 0, kotv_jvm_owner_thread, NULL, 0, &tid);
	if (!g_jvm_owner) {
		g_boot_rc = JNI_ERR;
		return JNI_ERR;
	}

	if (WaitForSingleObject(g_boot_done, 120000) != WAIT_OBJECT_0) {
		TerminateThread(g_jvm_owner, 1);
		CloseHandle(g_jvm_owner);
		g_jvm_owner = NULL;
		return JNI_ERR;
	}
	return (int)g_boot_rc;
}

static int kotv_jvm_post_job(kotv_jvm_job_kind kind, const char *json_in, char *json_out, int json_out_len, char *errbuf, int errbuf_len, DWORD timeout_ms) {
	HANDLE done;
	int rc;

	if (!g_jvm_owner || !g_vm)
		return -1;

	done = CreateEventW(NULL, TRUE, FALSE, NULL);
	if (!done)
		return -1;

	EnterCriticalSection(&g_jvm_job_lock);
	memset(&g_jvm_job, 0, sizeof(g_jvm_job));
	g_jvm_job.kind = kind;
	g_jvm_job.json_in = json_in;
	g_jvm_job.json_out = json_out;
	g_jvm_job.json_out_len = json_out_len;
	g_jvm_job.errbuf = errbuf;
	g_jvm_job.errbuf_len = errbuf_len;
	g_jvm_job.done = done;
	LeaveCriticalSection(&g_jvm_job_lock);

	ResetEvent(g_jvm_job_done);
	SetEvent(g_jvm_job_posted);

	if (WaitForSingleObject(done, timeout_ms) != WAIT_OBJECT_0) {
		write_err(errbuf, errbuf_len, "jvm job timeout");
		CloseHandle(done);
		/* 尽力打断 Java 里卡住的 OkHttp，避免 owner 线程长时间占用队列 */
		(void)kotv_jvm_cancel_async(NULL, 0);
		return -8;
	}

	EnterCriticalSection(&g_jvm_job_lock);
	rc = g_jvm_job.rc;
	LeaveCriticalSection(&g_jvm_job_lock);
	CloseHandle(done);
	return rc;
}

static void kotv_jvm_owner_shutdown(void) {
	if (!g_jvm_owner)
		return;
	kotv_jvm_post_job(KOTV_JVM_JOB_SHUTDOWN, NULL, NULL, 0, NULL, 0, 30000);
	WaitForSingleObject(g_jvm_owner, 5000);
	CloseHandle(g_jvm_owner);
	g_jvm_owner = NULL;
	if (g_jvm_job_posted) {
		CloseHandle(g_jvm_job_posted);
		g_jvm_job_posted = NULL;
	}
	if (g_jvm_job_done) {
		CloseHandle(g_jvm_job_done);
		g_jvm_job_done = NULL;
	}
	if (g_boot_done) {
		CloseHandle(g_boot_done);
		g_boot_done = NULL;
	}
	DeleteCriticalSection(&g_jvm_job_lock);
}

typedef struct {
	JavaVM *vm;
} kotv_jvm_cancel_ctx;

/* cancelAll 不排队等 owner 上的 CALL：独立 Win32 线程 Attach 后触发 OkHttp.cancelAll。 */
static DWORD WINAPI kotv_jvm_cancel_thread(LPVOID arg) {
	kotv_jvm_cancel_ctx *ctx = (kotv_jvm_cancel_ctx *)arg;
	JNIEnv *env = NULL;
	JavaVM *vm = ctx ? ctx->vm : NULL;
	DWORD ret = 0;

	/* 生命周期由线程自行收尾，避免调用方超时返回后的悬挂指针。 */
	free(ctx);
	if (!vm)
		return 1;
	if ((*vm)->AttachCurrentThread(vm, (void **)&env, NULL) != 0 || !env)
		return 1;
	/* 异步线程不能写调用方 errbuf（Go 栈上临时缓冲），统一忽略错误文本。 */
	(void)kotv_jvm_cancel_all_with_env(env, NULL, 0);
	(*vm)->DetachCurrentThread(vm);
	return ret;
}

static int kotv_jvm_cancel_async(char *errbuf, int errbuf_len) {
	kotv_jvm_cancel_ctx *ctx;
	HANDLE th;
	DWORD tid;

	if (!g_vm) {
		write_err(errbuf, errbuf_len, "jvm not started");
		return -1;
	}
	ctx = (kotv_jvm_cancel_ctx *)calloc(1, sizeof(*ctx));
	if (!ctx) {
		write_err(errbuf, errbuf_len, "alloc cancel ctx failed");
		return -1;
	}
	ctx->vm = g_vm;

	th = CreateThread(NULL, 0, kotv_jvm_cancel_thread, ctx, 0, &tid);
	if (!th) {
		free(ctx);
		write_err(errbuf, errbuf_len, "CreateThread for cancel failed");
		return -1;
	}
	CloseHandle(th);
	return 0;
}
#else
static jint kotv_jvm_owner_start(JNI_CreateJavaVM_t create, JavaVM **vm, JNIEnv **env, JavaVMInitArgs *args) {
	return create(vm, env, args);
}
#endif

int kotv_jvm_ready(void) { return g_vm != NULL ? 1 : 0; }

void kotv_jvm_shutdown(void) {
#if defined(_WIN32)
	kotv_jvm_owner_shutdown();
#else
	if (g_vm) {
		(*g_vm)->DestroyJavaVM(g_vm);
	}
	g_vm = NULL;
	g_env = NULL;
#endif
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
	char home_acp[1024];
	char jar_acp[4096];
	char cache_acp[1024];
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
#if defined(_WIN32)
		if (home[0] && utf8_to_acp(home, home_acp, (int)sizeof(home_acp)) == 0)
			snprintf(java_home_opt, sizeof(java_home_opt), "-Djava.home=%s", home_acp);
		else if (home[0])
			snprintf(java_home_opt, sizeof(java_home_opt), "-Djava.home=%s", home);
		else
			java_home_opt[0] = 0;
		if (utf8_to_acp(bridge_jar, jar_acp, (int)sizeof(jar_acp)) != 0)
			snprintf(jar_acp, sizeof(jar_acp), "%s", bridge_jar);
		if (cache_dir && cache_dir[0] && utf8_to_acp(cache_dir, cache_acp, (int)sizeof(cache_acp)) == 0)
			;
		else
			snprintf(cache_acp, sizeof(cache_acp), "%s", cache_dir ? cache_dir : ".");
		snprintf(cp, sizeof(cp), "-Djava.class.path=%s", jar_acp);
		snprintf(cache, sizeof(cache), "-Dkotv.cache.dir=%s", cache_acp);
#else
		if (home[0])
			snprintf(java_home_opt, sizeof(java_home_opt), "-Djava.home=%s", home);
		else
			java_home_opt[0] = 0;
		snprintf(cp, sizeof(cp), "-Djava.class.path=%s", bridge_jar);
		snprintf(cache, sizeof(cache), "-Dkotv.cache.dir=%s", cache_dir ? cache_dir : ".");
#endif
	}
	snprintf(proxy, sizeof(proxy), "-Dkotv.proxy.port=%d", proxy_port);

	JavaVMOption opts[22];
	int n = 0;
	opts[n++].optionString = strdup("-Djava.awt.headless=true");
	if (java_home_opt[0])
		opts[n++].optionString = strdup(java_home_opt);
	opts[n++].optionString = strdup(cp);
	opts[n++].optionString = strdup(cache);
	opts[n++].optionString = strdup(proxy);
	opts[n++].optionString = strdup("-Djava.net.useSystemProxies=false");
	opts[n++].optionString = strdup("-DsocksProxyHost=");
	opts[n++].optionString = strdup("-DsocksProxyPort=");
	opts[n++].optionString = strdup("-Dhttp.proxyHost=");
	opts[n++].optionString = strdup("-Dhttp.proxyPort=");
	opts[n++].optionString = strdup("-Dhttps.proxyHost=");
	opts[n++].optionString = strdup("-Dhttps.proxyPort=");
	opts[n++].optionString = strdup("-Dsun.net.client.defaultConnectTimeout=8000");
	opts[n++].optionString = strdup("-Dsun.net.client.defaultReadTimeout=10000");
	opts[n++].optionString = strdup("-Dfile.encoding=UTF-8");
	opts[n++].optionString = strdup("--add-opens=java.base/java.lang=ALL-UNNAMED");
	opts[n++].optionString = strdup("--add-opens=java.base/java.util=ALL-UNNAMED");

	JavaVMInitArgs args;
	memset(&args, 0, sizeof(args));
	args.version = JNI_VERSION_10;
	args.nOptions = n;
	args.options = opts;
	args.ignoreUnrecognized = JNI_TRUE;

#if defined(_WIN32)
	jint rc = kotv_jvm_owner_start(create, &args);
#else
	JavaVM *vm = NULL;
	JNIEnv *env = NULL;
	jint rc = kotv_jvm_owner_start(create, &vm, &env, &args);
#endif
	for (int i = 0; i < n; i++)
		free(opts[i].optionString);

	if (rc != 0
#if !defined(_WIN32)
	    || !vm || !env
#endif
	) {
		char msg[96];
		snprintf(msg, sizeof(msg), "JNI_CreateJavaVM failed (rc=%d)", (int)rc);
		write_err(errbuf, errbuf_len, msg);
		kotv_dlclose(g_jvm_lib);
		g_jvm_lib = NULL;
		return -4;
	}
#if !defined(_WIN32)
	g_vm = vm;
	g_env = env;
#endif
	return 0;
}

static int kotv_jvm_call_with_env(JNIEnv *env, const char *json_in, char *json_out, int json_out_len, char *errbuf, int errbuf_len) {
	if (!env || !json_in || !json_out || json_out_len <= 1) {
		write_err(errbuf, errbuf_len, "jvm not started");
		return -1;
	}

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

static int kotv_jvm_cancel_all_with_env(JNIEnv *env, char *errbuf, int errbuf_len) {
	if (!env) {
		write_err(errbuf, errbuf_len, "JNIEnv unavailable");
		return -1;
	}
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
	jstring jstr = (*env)->NewStringUTF(env, "{\"method\":\"cancelAll\"}");
	if (!jstr) {
		(*env)->DeleteLocalRef(env, cls);
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
		write_err(errbuf, errbuf_len, "Java exception in cancelAll");
		return -5;
	}
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
#if defined(_WIN32)
	/* 120s：JAR detailContent 可能含多次网络请求；与 Flutter /api/v1 120s 对齐 */
	return kotv_jvm_post_job(KOTV_JVM_JOB_CALL, json_in, json_out, json_out_len, errbuf, errbuf_len, 120000);
#else
	int attached = 0;
	JNIEnv *env = jvm_env_for_call(&attached);
	if (!env) {
		write_err(errbuf, errbuf_len, "JNIEnv unavailable");
		return -1;
	}
	int rc = kotv_jvm_call_with_env(env, json_in, json_out, json_out_len, errbuf, errbuf_len);
	if (attached)
		(*g_vm)->DetachCurrentThread(g_vm);
	return rc;
#endif
}

int kotv_jvm_cancel_all(char *errbuf, int errbuf_len) {
	if (!g_vm) {
		write_err(errbuf, errbuf_len, "jvm not started");
		return -1;
	}
#if defined(_WIN32)
	/* 不经过 owner job 队列，避免排在卡住的 CALL 后面 */
	return kotv_jvm_cancel_async(errbuf, errbuf_len);
#else
	int attached = 0;
	JNIEnv *env = jvm_env_for_call(&attached);
	if (!env) {
		write_err(errbuf, errbuf_len, "JNIEnv unavailable");
		return -1;
	}
	int rc = kotv_jvm_cancel_all_with_env(env, errbuf, errbuf_len);
	if (attached)
		(*g_vm)->DetachCurrentThread(g_vm);
	return rc;
#endif
}
