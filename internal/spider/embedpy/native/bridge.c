#include "bridge.h"
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

typedef void (*Py_Initialize_t)(void);
typedef void (*Py_Finalize_t)(void);
typedef int (*PyGILState_Ensure_t)(void);
typedef void (*PyGILState_Release_t)(int);
typedef void *(*PyEval_SaveThread_t)(void);
typedef void (*PyEval_RestoreThread_t)(void *);
typedef void *(*PyRun_String_t)(const char *, int, void *, void *);
typedef void *(*PyUnicode_FromString_t)(const char *);
typedef void *(*PyObject_CallFunctionObjArgs_t)(void *, ...);
typedef const char *(*PyUnicode_AsUTF8_t)(void *);
typedef void (*Py_DecRef_t)(void *);
typedef void *(*PyImport_AddModule_t)(const char *);
typedef void *(*PyModule_GetDict_t)(void *);
typedef void (*PyErr_Print_t)(void);
typedef void (*PyErr_Clear_t)(void);

enum { PY_FILE_INPUT = 257, PY_EVAL_INPUT = 258 };

static kotv_lib_t g_py_lib;
static int g_py_inited;
static void *g_save_tstate; /* PyEval_SaveThread 返回值，Finalize 前 Restore */
static Py_Initialize_t p_Py_Initialize;
static Py_Finalize_t p_Py_Finalize;
static PyGILState_Ensure_t p_PyGILState_Ensure;
static PyGILState_Release_t p_PyGILState_Release;
static PyEval_SaveThread_t p_PyEval_SaveThread;
static PyEval_RestoreThread_t p_PyEval_RestoreThread;
static PyRun_String_t p_PyRun_String;
static PyUnicode_FromString_t p_PyUnicode_FromString;
static PyObject_CallFunctionObjArgs_t p_PyObject_CallFunctionObjArgs;
static PyUnicode_AsUTF8_t p_PyUnicode_AsUTF8;
static Py_DecRef_t p_Py_DecRef;
static PyImport_AddModule_t p_PyImport_AddModule;
static PyModule_GetDict_t p_PyModule_GetDict;
static PyErr_Print_t p_PyErr_Print;
static PyErr_Clear_t p_PyErr_Clear;

#define MAX_SESSIONS 64
static void *g_dispatch[MAX_SESSIONS];

static void write_err(char *errbuf, int errbuf_len, const char *msg) {
	if (!errbuf || errbuf_len <= 0)
		return;
	snprintf(errbuf, (size_t)errbuf_len, "%s", msg ? msg : "unknown");
}

static void clear_err(void) {
	if (p_PyErr_Clear)
		p_PyErr_Clear();
}

static void print_err(void) {
	if (p_PyErr_Print)
		p_PyErr_Print();
	else
		clear_err();
}

static int load_symbols(char *errbuf, int errbuf_len) {
	p_Py_Initialize = (Py_Initialize_t)kotv_dlsym(g_py_lib, "Py_Initialize");
	p_Py_Finalize = (Py_Finalize_t)kotv_dlsym(g_py_lib, "Py_Finalize");
	p_PyGILState_Ensure = (PyGILState_Ensure_t)kotv_dlsym(g_py_lib, "PyGILState_Ensure");
	p_PyGILState_Release = (PyGILState_Release_t)kotv_dlsym(g_py_lib, "PyGILState_Release");
	p_PyEval_SaveThread = (PyEval_SaveThread_t)kotv_dlsym(g_py_lib, "PyEval_SaveThread");
	p_PyEval_RestoreThread = (PyEval_RestoreThread_t)kotv_dlsym(g_py_lib, "PyEval_RestoreThread");
	p_PyRun_String = (PyRun_String_t)kotv_dlsym(g_py_lib, "PyRun_String");
	p_PyUnicode_FromString = (PyUnicode_FromString_t)kotv_dlsym(g_py_lib, "PyUnicode_FromString");
	p_PyObject_CallFunctionObjArgs = (PyObject_CallFunctionObjArgs_t)kotv_dlsym(g_py_lib, "PyObject_CallFunctionObjArgs");
	p_PyUnicode_AsUTF8 = (PyUnicode_AsUTF8_t)kotv_dlsym(g_py_lib, "PyUnicode_AsUTF8");
	p_Py_DecRef = (Py_DecRef_t)kotv_dlsym(g_py_lib, "Py_DecRef");
	p_PyImport_AddModule = (PyImport_AddModule_t)kotv_dlsym(g_py_lib, "PyImport_AddModule");
	p_PyModule_GetDict = (PyModule_GetDict_t)kotv_dlsym(g_py_lib, "PyModule_GetDict");
	p_PyErr_Print = (PyErr_Print_t)kotv_dlsym(g_py_lib, "PyErr_Print");
	p_PyErr_Clear = (PyErr_Clear_t)kotv_dlsym(g_py_lib, "PyErr_Clear");
	/* Stable ABI 的 python3.dll 常缺 GIL；须加载 python3xx.dll */
	if (!p_PyGILState_Ensure || !p_PyGILState_Release || !p_PyEval_SaveThread) {
		write_err(errbuf, errbuf_len,
		          "missing GIL symbols (use python3xx.dll, not Stable ABI python3.dll)");
		return -1;
	}
	if (!p_Py_Initialize || !p_PyRun_String || !p_PyUnicode_FromString || !p_PyObject_CallFunctionObjArgs ||
	    !p_PyImport_AddModule || !p_PyModule_GetDict) {
		write_err(errbuf, errbuf_len, "missing python symbols");
		return -1;
	}
	return 0;
}

int kotv_embedpy_init(const char *py_lib, const char *py_home, char *errbuf, int errbuf_len) {
	if (g_py_inited)
		return 0;
	if (!py_lib) {
		write_err(errbuf, errbuf_len, "py_lib missing");
		return -1;
	}
	g_py_lib = kotv_dlopen(py_lib);
	if (!g_py_lib) {
		write_err(errbuf, errbuf_len, "dlopen libpython failed");
		return -2;
	}
	if (load_symbols(errbuf, errbuf_len) != 0)
		return -3;
	/* PYTHONHOME 必须在 Initialize 之前；事后改 sys.prefix 救不了 encodings。 */
	if (py_home && py_home[0]) {
#if defined(_WIN32)
		SetEnvironmentVariableA("PYTHONHOME", py_home);
#else
		setenv("PYTHONHOME", py_home, 1);
#endif
	}
	p_Py_Initialize();
	/* 关键键：Py_Initialize 后必须释放 GIL，否则其它 OS 线程 PyGILState_Ensure 会死锁（UI 表现为超时）。 */
	g_save_tstate = p_PyEval_SaveThread();
	g_py_inited = 1;
	return 0;
}

unsigned long long kotv_embedpy_start(const char *bootstrap_code, char *errbuf, int errbuf_len) {
	if (!g_py_inited) {
		write_err(errbuf, errbuf_len, "python not inited");
		return 0;
	}
	if (!bootstrap_code || !bootstrap_code[0]) {
		write_err(errbuf, errbuf_len, "bootstrap missing");
		return 0;
	}
	int slot = -1;
	for (int i = 0; i < MAX_SESSIONS; i++) {
		if (!g_dispatch[i]) {
			slot = i;
			break;
		}
	}
	if (slot < 0) {
		write_err(errbuf, errbuf_len, "python session table full");
		return 0;
	}

	int gil = p_PyGILState_Ensure();
	void *mainmod = p_PyImport_AddModule("__main__");
	void *globals = mainmod ? p_PyModule_GetDict(mainmod) : NULL;
	if (!globals) {
		p_PyGILState_Release(gil);
		write_err(errbuf, errbuf_len, "__main__ dict missing");
		return 0;
	}
	clear_err();
	void *res = p_PyRun_String(bootstrap_code, PY_FILE_INPUT, globals, globals);
	if (!res) {
		print_err();
		p_PyGILState_Release(gil);
		write_err(errbuf, errbuf_len, "python bootstrap failed");
		return 0;
	}
	if (p_Py_DecRef)
		p_Py_DecRef(res);
	void *dispatch = p_PyRun_String("__ref__", PY_EVAL_INPUT, globals, globals);
	if (!dispatch) {
		print_err();
		p_PyGILState_Release(gil);
		write_err(errbuf, errbuf_len, "kotv_dispatch_json missing");
		return 0;
	}
	g_dispatch[slot] = dispatch;
	p_PyGILState_Release(gil);
	return (unsigned long long)(slot + 1);
}

int kotv_embedpy_call(unsigned long long sid, const char *json_line, char *json_out, int json_out_len, char *errbuf, int errbuf_len) {
	if (sid == 0 || sid > MAX_SESSIONS) {
		write_err(errbuf, errbuf_len, "invalid session id");
		return -1;
	}
	int slot = (int)sid - 1;
	if (!g_dispatch[slot] || !json_line) {
		write_err(errbuf, errbuf_len, "no python session");
		return -1;
	}
	int gil = p_PyGILState_Ensure();
	clear_err();
	void *arg = p_PyUnicode_FromString(json_line);
	void *ret = p_PyObject_CallFunctionObjArgs(g_dispatch[slot], arg, NULL);
	if (p_Py_DecRef)
		p_Py_DecRef(arg);
	if (!ret) {
		print_err();
		p_PyGILState_Release(gil);
		write_err(errbuf, errbuf_len, "python dispatch failed");
		return -2;
	}
	const char *utf = p_PyUnicode_AsUTF8 ? p_PyUnicode_AsUTF8(ret) : NULL;
	if (!utf) {
		if (p_Py_DecRef)
			p_Py_DecRef(ret);
		p_PyGILState_Release(gil);
		write_err(errbuf, errbuf_len, "python result not str");
		return -3;
	}
	snprintf(json_out, (size_t)json_out_len, "%s", utf);
	if (p_Py_DecRef)
		p_Py_DecRef(ret);
	p_PyGILState_Release(gil);
	return 0;
}

void kotv_embedpy_stop(unsigned long long sid) {
	if (sid == 0 || sid > MAX_SESSIONS)
		return;
	int slot = (int)sid - 1;
	if (!g_dispatch[slot])
		return;
	int gil = p_PyGILState_Ensure();
	if (p_Py_DecRef)
		p_Py_DecRef(g_dispatch[slot]);
	g_dispatch[slot] = NULL;
	p_PyGILState_Release(gil);
}

void kotv_embedpy_shutdown(void) {
	int gil = 0;
	int held = 0;
	if (g_py_inited && p_PyGILState_Ensure) {
		gil = p_PyGILState_Ensure();
		held = 1;
	}
	for (int i = 0; i < MAX_SESSIONS; i++) {
		if (g_dispatch[i]) {
			if (p_Py_DecRef)
				p_Py_DecRef(g_dispatch[i]);
			g_dispatch[i] = NULL;
		}
	}
	if (held)
		p_PyGILState_Release(gil);
	/* Finalize 需要持有 GIL；Restore 初始化时 Save 的主线程状态最稳妥。 */
	if (g_save_tstate && p_PyEval_RestoreThread) {
		p_PyEval_RestoreThread(g_save_tstate);
		g_save_tstate = NULL;
	} else if (p_PyGILState_Ensure) {
		(void)p_PyGILState_Ensure();
	}
	if (g_py_inited && p_Py_Finalize)
		p_Py_Finalize();
	g_py_inited = 0;
	if (g_py_lib) {
		kotv_dlclose(g_py_lib);
		g_py_lib = NULL;
	}
}
