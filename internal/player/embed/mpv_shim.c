//go:build cgo

#include "mpv_shim.h"

#include <ctype.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdatomic.h>
#include <wchar.h>

/* 全平台：dlopen/LoadLibrary 失败详情（勿放进 _WIN32 块，否则 mac/linux/android 编译失败）。 */
static char g_load_detail[512];

#if defined(_WIN32)
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
typedef HMODULE mpv_lib_t;
static DWORD g_load_last_error;
static wchar_t *kotv_win_to_wide(const char *s, UINT cp) {
    int n;
    wchar_t *w;
    DWORD flags = (cp == CP_UTF8) ? MB_ERR_INVALID_CHARS : 0;
    if (!s || !s[0])
        return NULL;
    n = MultiByteToWideChar(cp, flags, s, -1, NULL, 0);
    if (n <= 0)
        return NULL;
    w = (wchar_t *)malloc((size_t)n * sizeof(wchar_t));
    if (!w)
        return NULL;
    if (MultiByteToWideChar(cp, flags, s, -1, w, n) <= 0) {
        free(w);
        return NULL;
    }
    return w;
}
static void kotv_win_set_dll_dir(const wchar_t *wlib) {
    wchar_t *dir;
    wchar_t *slash;
    wchar_t *slash2;
    if (!wlib)
        return;
    {
        size_t n = wcslen(wlib) + 1;
        dir = (wchar_t *)malloc(n * sizeof(wchar_t));
        if (!dir)
            return;
        memcpy(dir, wlib, n * sizeof(wchar_t));
    }
    slash = wcsrchr(dir, L'\\');
    slash2 = wcsrchr(dir, L'/');
    if (slash2 && (!slash || slash2 > slash))
        slash = slash2;
    if (slash) {
        *slash = L'\0';
        SetDllDirectoryW(dir);
    }
    free(dir);
}
/* 路径可能是 UTF-8（正确）或系统 ANSI（旧查找）。中文目录下只按 UTF-8 转会 LoadLibrary 失败。 */
static HMODULE kotv_load_library_utf8(const char *path) {
    static const UINT cps[] = {CP_UTF8, CP_ACP};
    HMODULE h = NULL;
    UINT prev;
    size_t i;
    g_load_last_error = 0;
    if (!path || !path[0])
        return NULL;
    prev = SetErrorMode(SEM_FAILCRITICALERRORS | SEM_NOOPENFILEERRORBOX);
    for (i = 0; i < sizeof(cps) / sizeof(cps[0]); ++i) {
        wchar_t *w = kotv_win_to_wide(path, cps[i]);
        if (!w)
            continue;
        kotv_win_set_dll_dir(w);
        h = LoadLibraryExW(w, NULL, LOAD_WITH_ALTERED_SEARCH_PATH);
        if (!h)
            h = LoadLibraryW(w);
        if (!h)
            g_load_last_error = GetLastError();
        free(w);
        if (h)
            break;
    }
    SetErrorMode(prev);
    return h;
}
static int kotv_win_file_in_dir(const wchar_t *dir, const wchar_t *name) {
    wchar_t path[MAX_PATH];
    DWORD attr;
    if (!dir || !name || !name[0])
        return 0;
    if (_snwprintf(path, MAX_PATH, L"%s\\%s", dir, name) <= 0)
        return 0;
    attr = GetFileAttributesW(path);
    return attr != INVALID_FILE_ATTRIBUTES && !(attr & FILE_ATTRIBUTE_DIRECTORY);
}
static void kotv_win_append_detail(const char *part) {
    size_t n;
    if (!part || !part[0])
        return;
    n = strlen(g_load_detail);
    if (n > 0 && n < sizeof(g_load_detail) - 2) {
        g_load_detail[n++] = ',';
        g_load_detail[n++] = ' ';
        g_load_detail[n] = '\0';
    }
    strncat(g_load_detail, part, sizeof(g_load_detail) - strlen(g_load_detail) - 1);
}
static int kotv_win_is_system_dll_a(const char *name) {
    char lower[128];
    size_t i, n;
    if (!name || !name[0])
        return 1;
    n = strlen(name);
    if (n >= sizeof(lower))
        n = sizeof(lower) - 1;
    for (i = 0; i < n; ++i)
        lower[i] = (char)tolower((unsigned char)name[i]);
    lower[n] = '\0';
    if (strncmp(lower, "api-ms-", 7) == 0 || strncmp(lower, "ext-ms-", 7) == 0)
        return 1;
    if (strcmp(lower, "kernel32.dll") == 0 || strcmp(lower, "user32.dll") == 0 ||
        strcmp(lower, "gdi32.dll") == 0 || strcmp(lower, "advapi32.dll") == 0 ||
        strcmp(lower, "shell32.dll") == 0 || strcmp(lower, "ole32.dll") == 0 ||
        strcmp(lower, "oleaut32.dll") == 0 || strcmp(lower, "ws2_32.dll") == 0 ||
        strcmp(lower, "ntdll.dll") == 0 || strcmp(lower, "msvcrt.dll") == 0 ||
        strcmp(lower, "ucrtbase.dll") == 0 || strcmp(lower, "vcruntime140.dll") == 0 ||
        strcmp(lower, "d3d11.dll") == 0 || strcmp(lower, "dxgi.dll") == 0 ||
        strcmp(lower, "opengl32.dll") == 0)
        return 1;
    return 0;
}
static int kotv_win_file_exists_ci(const wchar_t *dir, const char *name_a) {
    wchar_t wname[MAX_PATH];
    if (!dir || !name_a || !name_a[0])
        return 0;
    if (MultiByteToWideChar(CP_ACP, 0, name_a, -1, wname, (int)(sizeof(wname) / sizeof(wname[0]))) <= 0)
        return 0;
    return kotv_win_file_in_dir(dir, wname);
}
static const BYTE *kotv_win_rva_to_ptr(const IMAGE_NT_HEADERS *nt, const BYTE *base, DWORD rva) {
    PIMAGE_SECTION_HEADER sec;
    WORD i;
    if (!nt || !base || !rva)
        return NULL;
    sec = IMAGE_FIRST_SECTION(nt);
    for (i = 0; i < nt->FileHeader.NumberOfSections; ++i, ++sec) {
        DWORD va = sec->VirtualAddress;
        DWORD vs = sec->Misc.VirtualSize;
        if (rva >= va && rva < va + vs)
            return base + (rva - va) + sec->PointerToRawData;
    }
    return NULL;
}
static int kotv_win_try_load_path(const wchar_t *path, DWORD *err) {
    HMODULE h;
    UINT prev;
    if (!path)
        return 0;
    prev = SetErrorMode(SEM_FAILCRITICALERRORS | SEM_NOOPENFILEERRORBOX);
    h = LoadLibraryExW(path, NULL, LOAD_WITH_ALTERED_SEARCH_PATH);
    if (!h)
        h = LoadLibraryW(path);
    if (!h && err)
        *err = GetLastError();
    if (h)
        FreeLibrary(h);
    SetErrorMode(prev);
    return h != NULL;
}
static void kotv_win_check_import_table(const IMAGE_NT_HEADERS *nt, const BYTE *base,
                                        const wchar_t *dir, DWORD rva) {
    const IMAGE_IMPORT_DESCRIPTOR *imp;
    if (!rva)
        return;
    imp = (const IMAGE_IMPORT_DESCRIPTOR *)kotv_win_rva_to_ptr(nt, base, rva);
    if (!imp)
        return;
    for (; imp->Name; ++imp) {
        const char *dllname = (const char *)kotv_win_rva_to_ptr(nt, base, imp->Name);
        char note[160];
        if (!dllname || kotv_win_is_system_dll_a(dllname))
            continue;
        if (kotv_win_file_exists_ci(dir, dllname))
            continue;
        snprintf(note, sizeof(note), "import missing: %s", dllname);
        kotv_win_append_detail(note);
        if (_strnicmp(dllname, "libplacebo", 10) == 0) {
            WIN32_FIND_DATAW fd;
            wchar_t pattern[MAX_PATH];
            HANDLE fh;
            if (_snwprintf(pattern, MAX_PATH, L"%s\\libplacebo*.dll", dir) > 0) {
                fh = FindFirstFileW(pattern, &fd);
                if (fh != INVALID_HANDLE_VALUE) {
                    char have[96];
                    WideCharToMultiByte(CP_UTF8, 0, fd.cFileName, -1, have, (int)sizeof(have), NULL, NULL);
                    snprintf(note, sizeof(note), "have %s but mpv needs %s", have, dllname);
                    kotv_win_append_detail(note);
                    FindClose(fh);
                }
            }
        }
    }
}
static void kotv_win_check_delay_imports(const IMAGE_NT_HEADERS *nt, const BYTE *base,
                                         const wchar_t *dir, DWORD rva) {
    const IMAGE_DELAYLOAD_DESCRIPTOR *d;
    if (!rva)
        return;
    d = (const IMAGE_DELAYLOAD_DESCRIPTOR *)kotv_win_rva_to_ptr(nt, base, rva);
    if (!d)
        return;
    for (; d->DllNameRVA; ++d) {
        const char *dllname = (const char *)kotv_win_rva_to_ptr(nt, base, d->DllNameRVA);
        char note[160];
        if (!dllname || kotv_win_is_system_dll_a(dllname))
            continue;
        if (kotv_win_file_exists_ci(dir, dllname))
            continue;
        snprintf(note, sizeof(note), "delay-import missing: %s", dllname);
        kotv_win_append_detail(note);
    }
}
static void kotv_win_scan_pe_imports(const wchar_t *pe_path, const wchar_t *dir) {
    HANDLE hf = INVALID_HANDLE_VALUE;
    HANDLE hm = NULL;
    BYTE *view = NULL;
    IMAGE_DOS_HEADER *dos;
    IMAGE_NT_HEADERS *nt;
    if (!pe_path || !dir)
        return;
    hf = CreateFileW(pe_path, GENERIC_READ, FILE_SHARE_READ, NULL, OPEN_EXISTING,
                     FILE_ATTRIBUTE_NORMAL, NULL);
    if (hf == INVALID_HANDLE_VALUE)
        return;
    hm = CreateFileMappingW(hf, NULL, PAGE_READONLY, 0, 0, NULL);
    if (!hm)
        goto done;
    view = (BYTE *)MapViewOfFile(hm, FILE_MAP_READ, 0, 0, 0);
    if (!view)
        goto done;
    dos = (IMAGE_DOS_HEADER *)view;
    if (dos->e_magic != IMAGE_DOS_SIGNATURE)
        goto done;
    nt = (IMAGE_NT_HEADERS *)(view + dos->e_lfanew);
    if (nt->Signature != IMAGE_NT_SIGNATURE)
        goto done;
    kotv_win_check_import_table(nt, view, dir,
                                nt->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_IMPORT].VirtualAddress);
    kotv_win_check_delay_imports(nt, view, dir,
                                 nt->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_DELAY_IMPORT].VirtualAddress);
done:
    if (view)
        UnmapViewOfFile(view);
    if (hm)
        CloseHandle(hm);
    if (hf != INVALID_HANDLE_VALUE)
        CloseHandle(hf);
}
static void kotv_win_probe_load_chain(const wchar_t *dir) {
    static const wchar_t *candidates[] = {
        L"vulkan-1.dll",
        L"shaderc_shared.dll",
        L"libshaderc_shared.dll",
        L"SPIRV-Tools-shared.dll",
        NULL,
    };
    size_t i;
    wchar_t path[MAX_PATH];
    DWORD err;
    char note[128];
    SetDllDirectoryW(dir);
    for (i = 0; candidates[i]; ++i) {
        if (!kotv_win_file_in_dir(dir, candidates[i])) {
            if (wcscmp(candidates[i], L"vulkan-1.dll") == 0)
                kotv_win_append_detail("vulkan-1.dll missing (libplacebo needs it)");
            continue;
        }
        if (_snwprintf(path, MAX_PATH, L"%s\\%s", dir, candidates[i]) <= 0)
            continue;
        if (kotv_win_try_load_path(path, &err))
            continue;
        WideCharToMultiByte(CP_UTF8, 0, candidates[i], -1, note, (int)sizeof(note), NULL, NULL);
        snprintf(note + strlen(note), sizeof(note) - strlen(note), " load failed winerr=%lu", (unsigned long)err);
        kotv_win_append_detail(note);
    }
    {
        WIN32_FIND_DATAW fd;
        wchar_t pattern[MAX_PATH];
        HANDLE fh;
        if (_snwprintf(pattern, MAX_PATH, L"%s\\libplacebo*.dll", dir) > 0) {
            fh = FindFirstFileW(pattern, &fd);
            if (fh != INVALID_HANDLE_VALUE) {
                wchar_t ppath[MAX_PATH];
                if (_snwprintf(ppath, MAX_PATH, L"%s\\%s", dir, fd.cFileName) > 0 &&
                    !kotv_win_try_load_path(ppath, &err)) {
                    char ascii[96];
                    WideCharToMultiByte(CP_UTF8, 0, fd.cFileName, -1, ascii, (int)sizeof(ascii), NULL, NULL);
                    snprintf(note, sizeof(note), "%s load failed winerr=%lu", ascii, (unsigned long)err);
                    kotv_win_append_detail(note);
                }
                FindClose(fh);
            }
        }
    }
}
static void kotv_win_diagnose(const char *lib_path) {
    wchar_t *wlib;
    wchar_t dir[MAX_PATH];
    wchar_t *slash;
    g_load_detail[0] = '\0';
    wlib = kotv_win_to_wide(lib_path, CP_UTF8);
    if (!wlib)
        wlib = kotv_win_to_wide(lib_path, CP_ACP);
    if (!wlib)
        return;
    wcsncpy(dir, wlib, MAX_PATH - 1);
    dir[MAX_PATH - 1] = L'\0';
    slash = wcsrchr(dir, L'\\');
    if (!slash)
        slash = wcsrchr(dir, L'/');
    if (!slash) {
        free(wlib);
        return;
    }
    *slash = L'\0';
    kotv_win_scan_pe_imports(wlib, dir);
    kotv_win_probe_load_chain(dir);
    free(wlib);
}
static void kotv_win_preflight(const char *lib_path) {
    (void)lib_path;
}
#define MPV_OPEN(path) kotv_load_library_utf8(path)
#define MPV_SYM(lib, name) (void *)GetProcAddress(lib, name)
#define MPV_CLOSE(lib) FreeLibrary(lib)
#else
#include <dlfcn.h>
typedef void *mpv_lib_t;
#define MPV_OPEN(path) dlopen(path, RTLD_NOW | RTLD_LOCAL)
#define MPV_SYM(lib, name) dlsym(lib, name)
#define MPV_CLOSE(lib) dlclose(lib)
#endif

typedef struct mpv_handle mpv_handle;
typedef struct mpv_render_context mpv_render_context;

typedef struct {
    int type;
    void *data;
} mpv_render_param;

enum {
    MPV_FORMAT_STRING = 1,
    MPV_FORMAT_FLAG = 3,
    MPV_FORMAT_INT64 = 4,
    MPV_FORMAT_DOUBLE = 5,
};

enum {
    MPV_RENDER_PARAM_INVALID = 0,
    MPV_RENDER_PARAM_API_TYPE = 1,
    MPV_RENDER_PARAM_SW_SIZE = 17,
    MPV_RENDER_PARAM_SW_FORMAT = 18,
    MPV_RENDER_PARAM_SW_STRIDE = 19,
    MPV_RENDER_PARAM_SW_POINTER = 20,
};

enum { MPV_RENDER_UPDATE_FRAME = 1 };

typedef mpv_handle *(*fn_mpv_create)(void);
typedef int (*fn_mpv_initialize)(mpv_handle *);
typedef void (*fn_mpv_terminate_destroy)(mpv_handle *);
typedef int (*fn_mpv_set_option_string)(mpv_handle *, const char *, const char *);
typedef int (*fn_mpv_command)(mpv_handle *, const char **);
typedef int (*fn_mpv_get_property)(mpv_handle *, const char *, int, void *);
typedef int (*fn_mpv_set_property)(mpv_handle *, const char *, int, void *);
typedef int (*fn_mpv_set_property_string)(mpv_handle *, const char *, const char *);
typedef int (*fn_mpv_render_context_create)(mpv_render_context **, mpv_handle *,
                                            mpv_render_param *);
typedef void (*fn_mpv_render_context_free)(mpv_render_context *);
typedef void (*fn_mpv_render_context_set_update_callback)(mpv_render_context *,
                                                          void (*)(void *), void *);
typedef uint64_t (*fn_mpv_render_context_update)(mpv_render_context *);
typedef int (*fn_mpv_render_context_render)(mpv_render_context *, mpv_render_param *);
typedef void (*fn_mpv_free)(void *);
typedef struct mpv_event {
    int event_id;
    int error;
    uint64_t reply_userdata;
    void *data;
} mpv_event;
typedef mpv_event *(*fn_mpv_wait_event)(mpv_handle *, double);

enum { KOTV_MPV_EVENT_NONE = 0 };

static mpv_lib_t g_lib;
static mpv_handle *g_mpv;
static mpv_render_context *g_render;

static fn_mpv_create p_create;
static fn_mpv_initialize p_initialize;
static fn_mpv_terminate_destroy p_destroy;
static fn_mpv_set_option_string p_set_option_string;
static fn_mpv_command p_command;
static fn_mpv_get_property p_get_property;
static fn_mpv_set_property p_set_property;
static fn_mpv_set_property_string p_set_property_string;
static fn_mpv_render_context_create p_render_create;
static fn_mpv_render_context_free p_render_free;
static fn_mpv_render_context_set_update_callback p_render_set_update;
static fn_mpv_render_context_update p_render_update;
static fn_mpv_render_context_render p_render;
static fn_mpv_free p_mpv_free;
static fn_mpv_wait_event p_wait_event;
typedef void (*fn_mpv_wakeup)(mpv_handle *ctx);
typedef void (*fn_mpv_set_wakeup_callback)(mpv_handle *ctx, void (*cb)(void *d), void *d);
static fn_mpv_wakeup p_wakeup;
static fn_mpv_set_wakeup_callback p_set_wakeup_callback;

static volatile int g_dirty;
static atomic_int g_render_pending;
static kotv_mpv_wakeup_fn g_wakeup_fn;
static void *g_wakeup_user;
static int g_has_file;
static uint8_t *g_pixels;
static int g_width = 1280;
static int g_height = 720;
static int g_capacity;
static int g_hard; /* 1 = wid 硬渲，无 software render context */
static long long g_hard_win; /* 最近一次 wid 硬渲 HWND，供 reinit 复用 */
static int g_gpu_next;
static int g_vulkan;
static char g_gpu_api[32]; /* 空=auto；可为 d3d11/opengl/vulkan */
static char g_hwdec_opt[64];

static int init_sw(void);
static int init_wid(long long win);

static void mpv_wakeup_dispatch(void *ctx) {
    (void)ctx;
    if (g_wakeup_fn)
        g_wakeup_fn(g_wakeup_user);
}

static void update_cb(void *ctx) {
    (void)ctx;
    g_dirty = 1;
    atomic_store(&g_render_pending, 1);
    if (p_wakeup && g_mpv)
        p_wakeup(g_mpv);
}

void kotv_mpv_set_wakeup_handler(kotv_mpv_wakeup_fn fn, void *user) {
    g_wakeup_fn = fn;
    g_wakeup_user = user;
}

/* 按视频 dwidth/dheight 调整软渲缓冲；固定 1280x720 时 1080p 片源 render 会失败。 */
static int ensure_sw_buffer(void) {
    int64_t dw = 0;
    int64_t dh = 0;
    int nw;
    int nh;
    int need;
    if (!g_mpv || !p_get_property)
        return g_pixels && g_capacity > 0;
    /* 无有效视频尺寸时不渲：loadfile 后 demux 未就绪时 render 会 SIGABRT。 */
    if (p_get_property(g_mpv, "dwidth", MPV_FORMAT_INT64, &dw) < 0 || dw <= 0)
        return 0;
    if (p_get_property(g_mpv, "dheight", MPV_FORMAT_INT64, &dh) < 0 || dh <= 0)
        return 0;
    nw = (int)dw;
    nh = (int)dh;
    if (nw <= 0 || nh <= 0)
        return g_pixels && g_capacity > 0;
    if (nw > 3840)
        nw = 3840;
    if (nh > 2160)
        nh = 2160;
    need = nw * nh * 4;
    if (g_pixels && g_width == nw && g_height == nh && g_capacity >= need)
        return 1;
    free(g_pixels);
    g_pixels = (uint8_t *)malloc((size_t)need);
    if (!g_pixels) {
        g_capacity = 0;
        g_width = 1280;
        g_height = 720;
        return 0;
    }
    g_width = nw;
    g_height = nh;
    g_capacity = need;
    memset(g_pixels, 0, (size_t)need);
    g_dirty = 1;
    return 1;
}

static void copy_cstr(char *dst, size_t cap, const char *src) {
    size_t n;
    if (!dst || cap == 0)
        return;
    if (!src) {
        dst[0] = '\0';
        return;
    }
    n = strlen(src);
    if (n >= cap)
        n = cap - 1;
    memcpy(dst, src, n);
    dst[n] = '\0';
}

static char *dup_cstr(const char *s) {
    size_t n;
    char *p;
    if (!s)
        return NULL;
    n = strlen(s) + 1;
    p = (char *)malloc(n);
    if (p)
        memcpy(p, s, n);
    return p;
}

static int bind_symbols(void);

static int ensure_lib_loaded(const char *lib_path) {
    if (g_lib)
        return 0;
    if (!lib_path || !lib_path[0])
        return -1;
    g_load_detail[0] = '\0';
#if defined(_WIN32)
    kotv_win_preflight(lib_path);
#endif
    g_lib = MPV_OPEN(lib_path);
    if (!g_lib) {
#if defined(_WIN32)
        kotv_win_diagnose(lib_path);
        if (!g_load_detail[0] && g_load_last_error == 126)
            snprintf(g_load_detail, sizeof(g_load_detail),
                     "dependency DLL missing (winerr=126); check vulkan-1.dll / libplacebo version");
#else
        {
            const char *err = dlerror();
            if (err && err[0])
                snprintf(g_load_detail, sizeof(g_load_detail), "%s", err);
            else
                snprintf(g_load_detail, sizeof(g_load_detail), "dlopen failed: %s", lib_path);
        }
#endif
        return -2;
    }
    if (bind_symbols() != 0) {
        MPV_CLOSE(g_lib);
        g_lib = NULL;
        return -3;
    }
    return 0;
}

static int bind_symbols(void) {
    /* memcpy 避免 MSVC C4152（void* → 函数指针）。 */
#define BIND(dst, name) do { \
        void *_sym = (void *)MPV_SYM(g_lib, name); \
        if (!_sym) return -1; \
        memcpy(&(dst), &_sym, sizeof(dst)); \
    } while (0)
    BIND(p_create, "mpv_create");
    BIND(p_initialize, "mpv_initialize");
    BIND(p_destroy, "mpv_terminate_destroy");
    BIND(p_set_option_string, "mpv_set_option_string");
    BIND(p_command, "mpv_command");
    BIND(p_get_property, "mpv_get_property");
    BIND(p_set_property, "mpv_set_property");
    BIND(p_set_property_string, "mpv_set_property_string");
    BIND(p_render_create, "mpv_render_context_create");
    BIND(p_render_free, "mpv_render_context_free");
    BIND(p_render_set_update, "mpv_render_context_set_update_callback");
    BIND(p_render_update, "mpv_render_context_update");
    BIND(p_render, "mpv_render_context_render");
    BIND(p_mpv_free, "mpv_free");
    BIND(p_wait_event, "mpv_wait_event");
#undef BIND
#define BIND_OPT(dst, name) do { \
        void *_sym = (void *)MPV_SYM(g_lib, name); \
        if (_sym) memcpy(&(dst), &_sym, sizeof(dst)); \
    } while (0)
    BIND_OPT(p_wakeup, "mpv_wakeup");
    BIND_OPT(p_set_wakeup_callback, "mpv_set_wakeup_callback");
#undef BIND_OPT
    return 0;
}

/* libmpv 不排空事件队列时，后续 command 会返回 MPV_ERROR_EVENT_QUEUE_FULL (-1)。 */
static void drain_events(void) {
    int n;
    if (!g_mpv || !p_wait_event)
        return;
    for (n = 0; n < 512; ++n) {
        mpv_event *ev = p_wait_event(g_mpv, 0.0);
        if (!ev || ev->event_id == KOTV_MPV_EVENT_NONE)
            break;
    }
}

static void pump_events_timed(double timeout_sec) {
    int n;
    if (!g_mpv || !p_wait_event)
        return;
    for (n = 0; n < 64; ++n) {
        mpv_event *ev = p_wait_event(g_mpv, timeout_sec);
        if (!ev || ev->event_id == KOTV_MPV_EVENT_NONE)
            break;
    }
}

static void destroy_player(void) {
    if (g_render) {
        p_render_set_update(g_render, NULL, NULL);
        p_render_free(g_render);
        g_render = NULL;
    }
    if (g_mpv) {
        if (p_set_wakeup_callback)
            p_set_wakeup_callback(g_mpv, NULL, NULL);
        p_destroy(g_mpv);
        g_mpv = NULL;
    }
    g_hard = 0;
    g_hard_win = 0;
    g_has_file = 0;
}

static void apply_common_opts(mpv_handle *mpv) {
    p_set_option_string(mpv, "terminal", "no");
    p_set_option_string(mpv, "msg-level", "all=no");
    p_set_option_string(mpv, "keep-open", "yes");
    p_set_option_string(mpv, "input-default-bindings", "no");
    p_set_option_string(mpv, "input-vo-keyboard", "no");
    p_set_option_string(mpv, "osc", "no");
}

static void apply_gpu_render_opts(mpv_handle *mpv, int sw_vo) {
    if (g_hwdec_opt[0])
        p_set_option_string(mpv, "hwdec", g_hwdec_opt);
    if (sw_vo) {
        /* 桌面 Texture 软渲：只走 vo=libmpv，勿设 gpu-api=vulkan（libplacebo 会在 init 时拉 Vulkan）。 */
        p_set_option_string(mpv, "vo", "libmpv");
        if (!g_hwdec_opt[0])
            p_set_option_string(mpv, "hwdec", "auto");
        return;
    }
    p_set_option_string(mpv, "vo", g_gpu_next ? "gpu-next" : "gpu");
    p_set_option_string(mpv, "gpu-context", "auto");
    if (g_gpu_api[0])
        p_set_option_string(mpv, "gpu-api", g_gpu_api);
    else if (g_vulkan)
        p_set_option_string(mpv, "gpu-api", "vulkan");
    else
        p_set_option_string(mpv, "gpu-api", "auto");
}

int kotv_mpv_set_preinit_options(int gpu_next, int vulkan, const char *hwdec) {
    g_gpu_next = gpu_next ? 1 : 0;
    g_vulkan = vulkan ? 1 : 0;
    /* 不在这里清 g_gpu_api：由 kotv_mpv_set_gpu_api / set_preinit_options2 设置。 */
    if (g_vulkan && !g_gpu_api[0])
        copy_cstr(g_gpu_api, sizeof(g_gpu_api), "vulkan");
    g_hwdec_opt[0] = '\0';
    if (hwdec && hwdec[0])
        copy_cstr(g_hwdec_opt, sizeof(g_hwdec_opt), hwdec);
    return 0;
}

int kotv_mpv_set_gpu_api(const char *gpu_api) {
    g_gpu_api[0] = '\0';
    if (!gpu_api || !gpu_api[0] || strcmp(gpu_api, "auto") == 0)
        return 0;
    copy_cstr(g_gpu_api, sizeof(g_gpu_api), gpu_api);
    if (strcmp(g_gpu_api, "vulkan") == 0)
        g_vulkan = 1;
    return 0;
}

int kotv_mpv_set_preinit_options2(int gpu_next, int vulkan, const char *hwdec,
                                  const char *gpu_api) {
    kotv_mpv_set_gpu_api(gpu_api);
    return kotv_mpv_set_preinit_options(gpu_next, vulkan, hwdec);
}

int kotv_mpv_reinit_player(void) {
    int was_hard;
    long long win;
    if (!g_lib || !p_create)
        return -1;
    was_hard = g_hard;
    win = g_hard_win;
    destroy_player();
    if (was_hard && win)
        return init_wid(win);
    return init_sw();
}

int kotv_mpv_lib_has_vulkan(const char *lib_path) {
    static const char *needles[] = {"vulkan", "pl_vulkan", "-Dvulkan=enabled"};
    FILE *f;
    char buf[65536];
    size_t n, i, j;
    if (!lib_path || !lib_path[0])
        return 0;
    f = fopen(lib_path, "rb");
    if (!f)
        return 0;
    while ((n = fread(buf, 1, sizeof(buf), f)) > 0) {
        for (i = 0; i < n; ++i) {
            for (j = 0; j < sizeof(needles) / sizeof(needles[0]); ++j) {
                const char *nd = needles[j];
                const size_t len = strlen(nd);
                if (i + len <= n && memcmp(buf + i, nd, len) == 0) {
                    fclose(f);
                    return 1;
                }
            }
        }
    }
    fclose(f);
    return 0;
}

static int init_sw(void) {
    int attempt;
    for (attempt = 0; attempt < 2; ++attempt) {
        g_mpv = p_create();
        if (!g_mpv)
            return -4;
        apply_gpu_render_opts(g_mpv, 1);
        apply_common_opts(g_mpv);
        if (p_initialize(g_mpv) < 0) {
            destroy_player();
            /* Win7 等：Vulkan/gpu-next 初始化失败时退回默认再试一次。 */
            if (attempt == 0 && (g_vulkan || g_gpu_next)) {
                g_vulkan = 0;
                g_gpu_next = 0;
                continue;
            }
            return -5;
        }
        drain_events();
        if (p_set_wakeup_callback)
            p_set_wakeup_callback(g_mpv, mpv_wakeup_dispatch, NULL);
        break;
    }

    {
    char *api = "sw";
    mpv_render_param init_params[] = {
        {MPV_RENDER_PARAM_API_TYPE, api},
        {MPV_RENDER_PARAM_INVALID, NULL},
    };
    if (p_render_create(&g_render, g_mpv, init_params) < 0) {
        destroy_player();
        return -6;
    }
    p_render_set_update(g_render, update_cb, NULL);

    if (!g_pixels) {
        g_capacity = g_width * g_height * 4;
        g_pixels = (uint8_t *)malloc((size_t)g_capacity);
        if (!g_pixels) {
            destroy_player();
            return -7;
        }
        memset(g_pixels, 0, (size_t)g_capacity);
    }
    g_hard = 0;
    g_dirty = 1;
    return 0;
    }
}

static int init_wid(long long win) {
    if (!win)
        return -11;
    g_mpv = p_create();
    if (!g_mpv)
        return -4;
    {
        char widbuf[64];
        /* Windows: HWND；macOS: NSView*；X11: Window id。都按整数传给 wid。 */
        snprintf(widbuf, sizeof(widbuf), "%lld", win);
        p_set_option_string(g_mpv, "wid", widbuf);
    }
    apply_gpu_render_opts(g_mpv, 0);
    if (!g_hwdec_opt[0])
        p_set_option_string(g_mpv, "hwdec", "auto");
#if defined(__APPLE__)
    p_set_option_string(g_mpv, "force-window", "yes");
#endif
    apply_common_opts(g_mpv);
    if (p_initialize(g_mpv) < 0) {
        destroy_player();
        return -5;
    }
    drain_events();
    g_hard = 1;
    g_hard_win = win;
    g_dirty = 0;
    return 0;
}

int kotv_mpv_ensure_lib(const char *lib_path) {
    return ensure_lib_loaded(lib_path);
}

int kotv_mpv_lib_bound(void) {
    return g_lib ? 1 : 0;
}

int kotv_mpv_load(const char *lib_path) {
    if (g_mpv && (g_hard || (g_render && g_pixels)))
        return 0;
    {
        int rc = ensure_lib_loaded(lib_path);
        if (rc != 0)
            return rc;
    }
    return init_sw();
}

void kotv_mpv_unload(void) {
    destroy_player();
    free(g_pixels);
    g_pixels = NULL;
    g_capacity = 0;
    if (g_lib) {
        MPV_CLOSE(g_lib);
        g_lib = NULL;
    }
}

int kotv_mpv_loaded(void) {
    return g_mpv && g_lib && (g_hard || (g_render && g_pixels));
}

unsigned long kotv_mpv_last_load_error(void) {
#if defined(_WIN32)
    return (unsigned long)g_load_last_error;
#else
    return 0;
#endif
}

const char *kotv_mpv_last_load_detail(void) {
    return g_load_detail[0] ? g_load_detail : "";
}

int kotv_mpv_hard_active(void) {
    return g_hard && g_mpv ? 1 : 0;
}

int kotv_mpv_set_hard_win(long long win) {
    if (!g_lib || !p_create)
        return -1;
    destroy_player();
    if (win)
        return init_wid(win);
    return init_sw();
}

int kotv_mpv_play(const char *url) {
    int rc;
    const char *cmd[4];
    if (!g_mpv || !url)
        return -1;
    drain_events();
    cmd[0] = "loadfile";
    cmd[1] = url;
    cmd[2] = "replace";
    cmd[3] = NULL;
    rc = p_command(g_mpv, cmd);
    /* -1 = MPV_ERROR_EVENT_QUEUE_FULL：排空后再试一次（Win7 慢机常见）。 */
    if (rc == -1) {
        drain_events();
        rc = p_command(g_mpv, cmd);
    }
    if (rc >= 0) {
        g_has_file = 1;
    }
    return rc;
}

void kotv_mpv_stop(void) {
    int idle;
    int n;
    if (!g_mpv)
        return;
    {
        const char *cmd[] = {"stop", NULL};
        drain_events();
        p_command(g_mpv, cmd);
        drain_events();
    }
    /* 用户 stop/dispose：短等 core-idle 即可；长等会拖死返回。 */
    if (p_wait_event && p_get_property) {
        for (n = 0; n < 20; ++n) {
            idle = 0;
            p_get_property(g_mpv, "core-idle", MPV_FORMAT_FLAG, &idle);
            if (idle)
                break;
            {
                mpv_event *ev = p_wait_event(g_mpv, 0.05);
                if (ev && (ev->event_id == 1 || ev->event_id == 11)) /* SHUTDOWN / IDLE */
                    break;
            }
        }
        drain_events();
    }
    g_dirty = 0;
    g_has_file = 0;
    atomic_store(&g_render_pending, 0);
}

void kotv_mpv_pause(int pause) {
    if (!g_mpv)
        return;
    drain_events();
    p_set_property_string(g_mpv, "pause", pause ? "yes" : "no");
}

int kotv_mpv_is_playing(void) {
    if (!g_mpv)
        return 0;
    int paused = 0, idle = 1;
    p_get_property(g_mpv, "pause", MPV_FORMAT_FLAG, &paused);
    p_get_property(g_mpv, "core-idle", MPV_FORMAT_FLAG, &idle);
    return !paused && !idle;
}

int kotv_mpv_eof_reached(void) {
    int flag = 0;
    if (!g_mpv)
        return 0;
    if (p_get_property(g_mpv, "eof-reached", MPV_FORMAT_FLAG, &flag) < 0)
        return 0;
    return flag != 0;
}

void kotv_mpv_set_time(int64_t ms) {
    if (!g_mpv)
        return;
    double seconds = (double)ms / 1000.0;
    p_set_property(g_mpv, "time-pos", MPV_FORMAT_DOUBLE, &seconds);
}

static int64_t get_ms(const char *name) {
    if (!g_mpv)
        return 0;
    double seconds = 0;
    drain_events();
    if (p_get_property(g_mpv, name, MPV_FORMAT_DOUBLE, &seconds) < 0)
        return 0;
    return (int64_t)(seconds * 1000.0);
}

int64_t kotv_mpv_get_time(void) {
    return get_ms("time-pos");
}

int64_t kotv_mpv_get_length(void) {
    return get_ms("duration");
}

int kotv_mpv_set_volume(int volume) {
    if (!g_mpv)
        return -1;
    double value = (double)volume;
    drain_events();
    return p_set_property(g_mpv, "volume", MPV_FORMAT_DOUBLE, &value);
}

int kotv_mpv_set_prop_string(const char *name, const char *value) {
    if (!g_mpv || !name || !value)
        return -1;
    drain_events();
    return p_set_property_string(g_mpv, name, value);
}

int kotv_mpv_set_prop_double(const char *name, double value) {
    if (!g_mpv || !name)
        return -1;
    drain_events();
    return p_set_property(g_mpv, name, MPV_FORMAT_DOUBLE, &value);
}

int kotv_mpv_get_prop_double(const char *name, double *out) {
    if (!g_mpv || !name || !out)
        return -1;
    return p_get_property(g_mpv, name, MPV_FORMAT_DOUBLE, out);
}

int kotv_mpv_get_prop_int64(const char *name, int64_t *out) {
    if (!g_mpv || !name || !out)
        return -1;
    return p_get_property(g_mpv, name, MPV_FORMAT_INT64, out);
}

int kotv_mpv_cycle(const char *prop) {
    if (!g_mpv || !prop)
        return -1;
    const char *cmd[] = {"cycle", prop, NULL};
    return p_command(g_mpv, cmd);
}

int kotv_mpv_set_prop_int64(const char *name, int64_t value) {
    if (!g_mpv || !name)
        return -1;
    return p_set_property(g_mpv, name, MPV_FORMAT_INT64, &value);
}

/* 返回值需用 kotv_mpv_free_str 释放 */
char *kotv_mpv_get_prop_string(const char *name) {
    if (!g_mpv || !name)
        return NULL;
    char *out = NULL;
    if (p_get_property(g_mpv, name, MPV_FORMAT_STRING, &out) < 0)
        return NULL;
    return out;
}

void kotv_mpv_free_str(char *p) {
    if (p && p_mpv_free)
        p_mpv_free(p);
}

int kotv_mpv_cmd2(const char *a, const char *b) {
    if (!g_mpv || !a)
        return -1;
    const char *cmd[] = {a, b, NULL};
    return p_command(g_mpv, cmd);
}

static int mpv_vo_configured(void) {
    int ok = 0;
    if (!g_mpv || !p_get_property)
        return 0;
    if (p_get_property(g_mpv, "vo-configured", MPV_FORMAT_FLAG, &ok) < 0)
        return 0;
    return ok ? 1 : 0;
}

int kotv_mpv_vo_configured(void) {
    return mpv_vo_configured();
}

void kotv_mpv_pump_events(void) {
    pump_events_timed(0.01);
}

int kotv_mpv_take_frame(uint8_t *out, int out_cap, int *out_w, int *out_h) {
    if (g_hard || !g_has_file || !g_render || !out || !out_w || !out_h)
        return 0;
    /* 仅 render update_cb 置位后尝试；避免 tick 轮询与 demux/decode 线程竞态 SIGABRT。 */
    if (!atomic_exchange(&g_render_pending, 0))
        return 0;
    pump_events_timed(0.0);
    if (!mpv_vo_configured())
        return 0;
    {
        double pt = -1.0;
        if (p_get_property && p_get_property(g_mpv, "playback-time", MPV_FORMAT_DOUBLE, &pt) >= 0 &&
            pt <= 0.0)
            return 0;
    }
    pump_events_timed(0.0);
    if (!ensure_sw_buffer())
        return 0;
    uint64_t update = p_render_update(g_render);
    if (!(update & MPV_RENDER_UPDATE_FRAME))
        return 0;

    int size[2] = {g_width, g_height};
    char *format = "rgb0";
    size_t stride = (size_t)g_width * 4;
    mpv_render_param params[] = {
        {MPV_RENDER_PARAM_SW_SIZE, size},
        {MPV_RENDER_PARAM_SW_FORMAT, format},
        {MPV_RENDER_PARAM_SW_STRIDE, &stride},
        {MPV_RENDER_PARAM_SW_POINTER, g_pixels},
        {MPV_RENDER_PARAM_INVALID, NULL},
    };
    if (p_render(g_render, params) < 0)
        return 0;
    int need = g_width * g_height * 4;
    if (out_cap < need)
        return 0;
    memcpy(out, g_pixels, (size_t)need);
    for (int i = 0; i < g_width * g_height; i++)
        out[i * 4 + 3] = 255;
    *out_w = g_width;
    *out_h = g_height;
    g_dirty = 0;
    return 1;
}

static void json_escape_append(char *dst, size_t cap, size_t *pos, const char *src) {
    size_t i;
    if (!dst || !src || !pos || *pos >= cap)
        return;
    for (i = 0; src[i] && *pos + 2 < cap; ++i) {
        char c = src[i];
        if (c == '\\' || c == '"') {
            if (*pos + 3 >= cap)
                break;
            dst[(*pos)++] = '\\';
        }
        dst[(*pos)++] = c;
    }
    dst[*pos] = '\0';
}

char *kotv_mpv_get_audio_tracks_json(void) {
    char *out;
    size_t pos = 0;
    const size_t cap = 16384;
    int64_t count = 0;
    int i;
#if defined(__APPLE__)
    /* macOS 软渲：demux/解码活跃期查 track-list 会触发 libmpv SIGABRT。 */
    return dup_cstr("[]");
#endif
    if (!g_mpv)
        return dup_cstr("[]");
    pump_events_timed(0.0);
    if (!mpv_vo_configured())
        return dup_cstr("[]");
    out = (char *)malloc(cap);
    if (!out)
        return NULL;
    out[pos++] = '[';
    out[pos] = '\0';
    if (p_get_property(g_mpv, "track-list/count", MPV_FORMAT_INT64, &count) < 0)
        count = 0;
    for (i = 0; i < (int)count && pos + 256 < cap; ++i) {
        char key[64];
        char *type = NULL;
        char *id = NULL;
        char *title = NULL;
        char *lang = NULL;
        char *codec = NULL;
        int first = (pos == 1);
        snprintf(key, sizeof(key), "track-list/%d/type", i);
        type = kotv_mpv_get_prop_string(key);
        if (!type || strcmp(type, "audio") != 0) {
            kotv_mpv_free_str(type);
            continue;
        }
        if (!first && pos + 1 < cap)
            out[pos++] = ',';
        snprintf(key, sizeof(key), "track-list/%d/id", i);
        id = kotv_mpv_get_prop_string(key);
        snprintf(key, sizeof(key), "track-list/%d/title", i);
        title = kotv_mpv_get_prop_string(key);
        snprintf(key, sizeof(key), "track-list/%d/lang", i);
        lang = kotv_mpv_get_prop_string(key);
        snprintf(key, sizeof(key), "track-list/%d/codec", i);
        codec = kotv_mpv_get_prop_string(key);
        pos += (size_t)snprintf(out + pos, cap - pos, "{\"id\":\"");
        json_escape_append(out, cap, &pos, id && id[0] ? id : "auto");
        pos += (size_t)snprintf(out + pos, cap - pos, "\",\"title\":\"");
        json_escape_append(out, cap, &pos, title && title[0] ? title : "");
        pos += (size_t)snprintf(out + pos, cap - pos, "\",\"lang\":\"");
        json_escape_append(out, cap, &pos, lang && lang[0] ? lang : "");
        pos += (size_t)snprintf(out + pos, cap - pos, "\",\"codec\":\"");
        json_escape_append(out, cap, &pos, codec && codec[0] ? codec : "");
        pos += (size_t)snprintf(out + pos, cap - pos, "\"}");
        kotv_mpv_free_str(type);
        kotv_mpv_free_str(id);
        kotv_mpv_free_str(title);
        kotv_mpv_free_str(lang);
        kotv_mpv_free_str(codec);
    }
    if (pos + 2 < cap) {
        out[pos++] = ']';
        out[pos] = '\0';
    }
    return out;
}
