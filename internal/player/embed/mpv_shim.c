//go:build cgo

#include "mpv_shim.h"

#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>

#if defined(_WIN32)
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
typedef HMODULE mpv_lib_t;
/* Go 传入 UTF-8 路径；LoadLibraryA 在中文 Windows 上会把路径解成系统 ANSI 而失败。 */
static HMODULE kotv_load_library_utf8(const char *utf8) {
    int n;
    wchar_t *w;
    HMODULE h;
    if (!utf8 || !utf8[0])
        return NULL;
    n = MultiByteToWideChar(CP_UTF8, 0, utf8, -1, NULL, 0);
    if (n <= 0)
        return NULL;
    w = (wchar_t *)malloc((size_t)n * sizeof(wchar_t));
    if (!w)
        return NULL;
    if (MultiByteToWideChar(CP_UTF8, 0, utf8, -1, w, n) <= 0) {
        free(w);
        return NULL;
    }
    h = LoadLibraryW(w);
    free(w);
    return h;
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

static volatile int g_dirty;
static uint8_t *g_pixels;
static int g_width = 1280;
static int g_height = 720;
static int g_capacity;
static int g_hard; /* 1 = wid 硬渲，无 software render context */
static int g_gpu_next;
static int g_vulkan;
static char g_hwdec_opt[64];

static int init_sw(void);

static void update_cb(void *ctx) {
    (void)ctx;
    g_dirty = 1;
}

static int bind_symbols(void) {
#define BIND(dst, name) do { dst = (void *)MPV_SYM(g_lib, name); if (!dst) return -1; } while (0)
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
#undef BIND
    return 0;
}

static void destroy_player(void) {
    if (g_render) {
        p_render_set_update(g_render, NULL, NULL);
        p_render_free(g_render);
        g_render = NULL;
    }
    if (g_mpv) {
        p_destroy(g_mpv);
        g_mpv = NULL;
    }
    g_hard = 0;
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
        p_set_option_string(mpv, "vo", "libmpv");
    } else {
        p_set_option_string(mpv, "vo", g_gpu_next ? "gpu-next" : "gpu");
        p_set_option_string(mpv, "gpu-context", "auto");
    }
    if (g_vulkan)
        p_set_option_string(mpv, "gpu-api", "vulkan");
    else
        p_set_option_string(mpv, "gpu-api", "auto");
}

int kotv_mpv_set_preinit_options(int gpu_next, int vulkan, const char *hwdec) {
    g_gpu_next = gpu_next ? 1 : 0;
    g_vulkan = vulkan ? 1 : 0;
    g_hwdec_opt[0] = '\0';
    if (hwdec && hwdec[0])
        strncpy(g_hwdec_opt, hwdec, sizeof(g_hwdec_opt) - 1);
    return 0;
}

int kotv_mpv_reinit_player(void) {
    if (!g_lib || !p_create)
        return -1;
    destroy_player();
    if (g_hard)
        return -2;
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
    g_mpv = p_create();
    if (!g_mpv)
        return -4;
    apply_gpu_render_opts(g_mpv, 1);
    apply_common_opts(g_mpv);
    if (p_initialize(g_mpv) < 0) {
        destroy_player();
        return -5;
    }

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
    apply_common_opts(g_mpv);
    if (p_initialize(g_mpv) < 0) {
        destroy_player();
        return -5;
    }
    g_hard = 1;
    g_dirty = 0;
    return 0;
}

int kotv_mpv_load(const char *lib_path) {
    if (g_mpv && (g_hard || (g_render && g_pixels)))
        return 0;
    if (!lib_path || !lib_path[0])
        return -1;
#if defined(_WIN32)
    /* 依赖 DLL 与 libmpv 同目录；中文安装路径需用宽字符 DLL 搜索目录。 */
    {
        int n = MultiByteToWideChar(CP_UTF8, 0, lib_path, -1, NULL, 0);
        if (n > 0) {
            wchar_t *w = (wchar_t *)malloc((size_t)n * sizeof(wchar_t));
            if (w && MultiByteToWideChar(CP_UTF8, 0, lib_path, -1, w, n) > 0) {
                wchar_t *slash = wcsrchr(w, L'\\');
                wchar_t *slash2 = wcsrchr(w, L'/');
                if (slash2 && (!slash || slash2 > slash))
                    slash = slash2;
                if (slash) {
                    *slash = L'\0';
                    SetDllDirectoryW(w);
                }
            }
            free(w);
        }
    }
#endif
    if (!g_lib) {
        g_lib = MPV_OPEN(lib_path);
        if (!g_lib)
            return -2;
        if (bind_symbols() != 0) {
            MPV_CLOSE(g_lib);
            g_lib = NULL;
            return -3;
        }
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
    if (!g_mpv || !url)
        return -1;
    const char *cmd[] = {"loadfile", url, "replace", NULL};
    int rc = p_command(g_mpv, cmd);
    if (rc >= 0)
        g_dirty = 1;
    return rc;
}

void kotv_mpv_stop(void) {
    if (!g_mpv)
        return;
    const char *cmd[] = {"stop", NULL};
    p_command(g_mpv, cmd);
    g_dirty = 0;
}

void kotv_mpv_pause(int pause) {
    if (g_mpv)
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
    return p_set_property(g_mpv, "volume", MPV_FORMAT_DOUBLE, &value);
}

int kotv_mpv_set_prop_string(const char *name, const char *value) {
    if (!g_mpv || !name || !value)
        return -1;
    return p_set_property_string(g_mpv, name, value);
}

int kotv_mpv_set_prop_double(const char *name, double value) {
    if (!g_mpv || !name)
        return -1;
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

int kotv_mpv_take_frame(uint8_t *out, int out_cap, int *out_w, int *out_h) {
    if (g_hard || !g_render || !g_pixels || !out || !out_w || !out_h)
        return 0;
    uint64_t update = p_render_update(g_render);
    if (!(update & MPV_RENDER_UPDATE_FRAME) && !g_dirty)
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
    if (!g_mpv)
        return strdup("[]");
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
