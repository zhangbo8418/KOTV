
// vlc_shim.c — dlopen/LoadLibrary libvlc + RV32 帧回调
#include "vlc_shim.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

#if !defined(_WIN32)
#include <unistd.h> /* setenv / sysconf */
#include <time.h>   /* clock_gettime */
#include <strings.h> /* strncasecmp */
#endif

#if defined(__APPLE__)
#include <sys/types.h>
#include <sys/sysctl.h>
#endif

#if defined(_WIN32)
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
typedef HMODULE lib_handle_t;
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
#define DL_OPEN(p) kotv_load_library_utf8(p)
#define DL_SYM(h, n) (void *)GetProcAddress(h, n)
#define DL_CLOSE(h) FreeLibrary(h)
#else
#include <dlfcn.h>
typedef void *lib_handle_t;
#define DL_OPEN(p) dlopen(p, RTLD_NOW | RTLD_LOCAL)
#define DL_SYM(h, n) dlsym(h, n)
#define DL_CLOSE(h) dlclose(h)
#endif

/* 单调毫秒时钟：缓冲事件新鲜度与速度差分都要用 */
static int64_t kotv_now_ms(void) {
#if defined(_WIN32)
	return (int64_t)GetTickCount64();
#else
	struct timespec ts;
#if defined(CLOCK_MONOTONIC)
	if (clock_gettime(CLOCK_MONOTONIC, &ts) == 0)
		return (int64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
#endif
	return 0;
#endif
}

/* ---- 帧缓冲锁：display_cb(VLC 线程) 与 take_frame(Go 轮询) 竞争 front 缓冲 ---- */
#if defined(_WIN32)
static CRITICAL_SECTION g_flock;
static int g_flock_init = 0;
static void flock_init(void) {
	if (!g_flock_init) {
		InitializeCriticalSection(&g_flock);
		g_flock_init = 1;
	}
}
#define FLOCK() EnterCriticalSection(&g_flock)
#define FUNLOCK() LeaveCriticalSection(&g_flock)
#else
#include <pthread.h>
static pthread_mutex_t g_flock = PTHREAD_MUTEX_INITIALIZER;
static void flock_init(void) {}
#define FLOCK() pthread_mutex_lock(&g_flock)
#define FUNLOCK() pthread_mutex_unlock(&g_flock)
#endif

/* ---- opaque libvlc types ---- */
typedef struct libvlc_instance_t libvlc_instance_t;
typedef struct libvlc_media_t libvlc_media_t;
typedef struct libvlc_media_player_t libvlc_media_player_t;

typedef void *(*vlc_video_lock_cb)(void *opaque, void **planes);
typedef void (*vlc_video_unlock_cb)(void *opaque, void *picture, void *const *planes);
typedef void (*vlc_video_display_cb)(void *opaque, void *picture);
typedef unsigned (*vlc_video_format_cb)(void **opaque, char *chroma,
                                       unsigned *width, unsigned *height,
                                       unsigned *pitches, unsigned *lines);
typedef void (*vlc_video_cleanup_cb)(void *opaque);

typedef libvlc_instance_t *(*fn_libvlc_new)(int, const char *const *);
typedef void (*fn_libvlc_release)(libvlc_instance_t *);
typedef libvlc_media_player_t *(*fn_libvlc_media_player_new)(libvlc_instance_t *);
typedef void (*fn_libvlc_media_player_release)(libvlc_media_player_t *);
typedef libvlc_media_t *(*fn_libvlc_media_new_location)(libvlc_instance_t *, const char *);
typedef void (*fn_libvlc_media_release)(libvlc_media_t *);
typedef void (*fn_libvlc_media_player_set_media)(libvlc_media_player_t *, libvlc_media_t *);
typedef int (*fn_libvlc_media_player_play)(libvlc_media_player_t *);
typedef void (*fn_libvlc_media_player_stop)(libvlc_media_player_t *);
typedef void (*fn_libvlc_media_player_set_pause)(libvlc_media_player_t *, int);
typedef int (*fn_libvlc_media_player_is_playing)(libvlc_media_player_t *);
typedef int (*fn_libvlc_media_player_get_state)(libvlc_media_player_t *);
typedef void (*fn_libvlc_media_player_set_time)(libvlc_media_player_t *, int64_t);
typedef int64_t (*fn_libvlc_media_player_get_time)(libvlc_media_player_t *);
typedef int64_t (*fn_libvlc_media_player_get_length)(libvlc_media_player_t *);
typedef int (*fn_libvlc_audio_set_volume)(libvlc_media_player_t *, int);
typedef void (*fn_libvlc_video_set_callbacks)(libvlc_media_player_t *,
                                             vlc_video_lock_cb, vlc_video_unlock_cb,
                                             vlc_video_display_cb, void *);
typedef void (*fn_libvlc_video_set_format_callbacks)(libvlc_media_player_t *,
                                                    vlc_video_format_cb,
                                                    vlc_video_cleanup_cb);
typedef void (*fn_libvlc_media_player_set_hwnd)(libvlc_media_player_t *, void *);
typedef void (*fn_libvlc_media_player_set_nsobject)(libvlc_media_player_t *, void *);
typedef void (*fn_libvlc_media_player_set_xwindow)(libvlc_media_player_t *, uint32_t);

/* ---- 扩展控制（可选符号，缺失时相关功能返回不支持） ---- */
typedef struct libvlc_track_description_t {
	int i_id;
	char *psz_name;
	struct libvlc_track_description_t *p_next;
} libvlc_track_description_t;

typedef int (*fn_libvlc_media_player_set_rate)(libvlc_media_player_t *, float);
typedef float (*fn_libvlc_media_player_get_rate)(libvlc_media_player_t *);
typedef int (*fn_libvlc_video_get_size)(libvlc_media_player_t *, unsigned, unsigned *, unsigned *);
typedef libvlc_track_description_t *(*fn_track_desc)(libvlc_media_player_t *);
typedef void (*fn_track_desc_release)(libvlc_track_description_t *);
typedef int (*fn_track_get)(libvlc_media_player_t *);
typedef int (*fn_track_set)(libvlc_media_player_t *, int);
typedef int (*fn_add_slave)(libvlc_media_player_t *, int, const char *, int);
typedef int (*fn_set_spu_delay)(libvlc_media_player_t *, int64_t);
typedef void (*fn_media_add_option)(libvlc_media_t *, const char *);

/* 事件（缓冲进度）；符号缺失时缓冲条退回当前位置 */
typedef struct libvlc_event_manager_t libvlc_event_manager_t;
typedef struct libvlc_event_t {
	int type;
	void *p_obj;
	union {
		struct {
			float new_cache;
		} media_player_buffering;
		char pad[64];
	} u;
} libvlc_event_t;
typedef void (*libvlc_callback_t)(const libvlc_event_t *, void *);
typedef libvlc_event_manager_t *(*fn_mp_event_manager)(libvlc_media_player_t *);
typedef int (*fn_event_attach)(libvlc_event_manager_t *, int, libvlc_callback_t, void *);
typedef libvlc_media_t *(*fn_mp_get_media)(libvlc_media_player_t *);
typedef struct libvlc_media_stats_t {
	int i_read_bytes;
	float f_input_bitrate;
	int i_demux_read_bytes;
	float f_demux_bitrate;
	int i_demux_corrupted;
	int i_demux_discontinuity;
	int i_decoded_video;
	int i_decoded_audio;
	int i_displayed_pictures;
	int i_lost_pictures;
	int i_played_abuffers;
	int i_lost_abuffers;
	int i_sent_packets;
	int i_sent_bytes;
	float f_send_bitrate;
} libvlc_media_stats_t;
typedef int (*fn_media_get_stats)(libvlc_media_t *, libvlc_media_stats_t *);
/* libvlc_events.h：MediaChanged=0x100 起顺序递增 */
enum {
	KOTV_VLC_EVENT_BUFFERING = 0x103,
	KOTV_VLC_EVENT_PLAYING = 0x104,
	KOTV_VLC_EVENT_PAUSED = 0x105,
	KOTV_VLC_EVENT_STOPPED = 0x106,
};

static lib_handle_t g_lib;
static lib_handle_t g_libcore; /* optional, some platforms need vlccore first */

static fn_libvlc_new p_new;
static fn_libvlc_release p_release;
static fn_libvlc_media_player_new p_mp_new;
static fn_libvlc_media_player_release p_mp_release;
static fn_libvlc_media_new_location p_media_new;
static fn_libvlc_media_release p_media_release;
static fn_libvlc_media_player_set_media p_set_media;
static fn_libvlc_media_player_play p_play;
static fn_libvlc_media_player_stop p_stop;
static fn_libvlc_media_player_set_pause p_set_pause;
static fn_libvlc_media_player_is_playing p_is_playing;
static fn_libvlc_media_player_get_state p_get_state;
static fn_libvlc_media_player_set_time p_set_time;
static fn_libvlc_media_player_get_time p_get_time;
static fn_libvlc_media_player_get_length p_get_length;
static fn_libvlc_audio_set_volume p_set_volume;
static fn_libvlc_video_set_callbacks p_set_callbacks;
static fn_libvlc_video_set_format_callbacks p_set_format_callbacks;
static fn_libvlc_media_player_set_hwnd p_set_hwnd;
static fn_libvlc_media_player_set_nsobject p_set_nsobject;
static fn_libvlc_media_player_set_xwindow p_set_xwindow;

static fn_libvlc_media_player_set_rate p_set_rate;
static fn_libvlc_media_player_get_rate p_get_rate;
static fn_libvlc_video_get_size p_video_get_size;
static fn_track_desc p_audio_desc;
static fn_track_desc p_spu_desc;
static fn_track_desc_release p_track_release;
static fn_track_get p_audio_get;
static fn_track_set p_audio_set;
static fn_track_get p_spu_get;
static fn_track_set p_spu_set;
static fn_add_slave p_add_slave;
static fn_set_spu_delay p_set_spu_delay;
static fn_media_add_option p_media_add_option;
static fn_mp_event_manager p_mp_event_manager;
static fn_event_attach p_event_attach;
static fn_mp_get_media p_mp_get_media;
static fn_media_get_stats p_media_get_stats;

/* -1 = 未设置（保持 libvlc 默认），0 = 硬解，1 = 软解 */
static int g_soft_decode = -1; /* -1=auto / 1=soft / 0=hard；由控件设置 */
/* 单集循环：建 media 时附加 :input-repeat */
static int g_repeat_one = 0;
static int g_hard;
static void *g_hwnd;
/* MediaPlayerBuffering 的 cache 百分比 0–100 */
static volatile float g_buffer_pct = 0.f;
/* 最近一次 buffering 事件时刻；陈旧事件不得再判为"缓冲中"（否则一直假缓冲） */
static volatile int64_t g_buffer_at_ms = 0;
/* 实际下发给 libvlc 的 network-caching（ms），用于估算已缓冲时长 */
static int g_cache_ms = 3000;

/* 速度差分采样：libvlc 只给累计字节，自己按时间差算 bytes/s */
static int64_t g_speed_last_bytes = -1;
static int64_t g_speed_last_at_ms = 0;
static int64_t g_speed_bps = 0;

/* 播放进度是否仍在推进：cache 事件常在正常预读时也发，只有"卡住"才算缓冲 */
static int64_t g_pos_last_ms = -1;
static int64_t g_pos_last_at_ms = 0;

static libvlc_instance_t *g_inst;
static libvlc_media_player_t *g_mp;

typedef struct {
	uint8_t *pixels;
	int w, h, pitch;
	int cap;
	volatile int dirty;
	uint8_t *front; /* display 时交换给 Go 读的副本 */
	int front_w, front_h, front_cap;
	volatile int64_t seq; /* 每 display 一帧自增，供 watchdog 判活 */
} FrameBuf;

static FrameBuf g_frame;
static int64_t g_frame_at_ms = 0; /* 最近一帧 display 时间，用于区分「真缓冲」与「直播有画」 */

static void frame_free(void) {
	FLOCK();
	free(g_frame.pixels);
	free(g_frame.front);
	memset(&g_frame, 0, sizeof(g_frame));
	FUNLOCK();
}

static int frame_ensure(int w, int h) {
	int pitch = w * 4;
	int need = pitch * h;
	if (need <= 0)
		return -1;
	FLOCK();
	int rc = 0;
	if (g_frame.cap < need) {
		uint8_t *p = (uint8_t *)realloc(g_frame.pixels, (size_t)need);
		if (!p) {
			rc = -1;
			goto done;
		}
		g_frame.pixels = p;
		g_frame.cap = need;
	}
	if (g_frame.front_cap < need) {
		uint8_t *p = (uint8_t *)realloc(g_frame.front, (size_t)need);
		if (!p) {
			rc = -1;
			goto done;
		}
		g_frame.front = p;
		g_frame.front_cap = need;
	}
	g_frame.w = w;
	g_frame.h = h;
	g_frame.pitch = pitch;
done:
	FUNLOCK();
	return rc;
}

static void *lock_cb(void *opaque, void **planes) {
	(void)opaque;
	*planes = g_frame.pixels;
	return NULL;
}

static void unlock_cb(void *opaque, void *picture, void *const *planes) {
	(void)opaque;
	(void)picture;
	(void)planes;
}

static void display_cb(void *opaque, void *picture) {
	(void)opaque;
	(void)picture;
	FLOCK();
	if (g_frame.pixels && g_frame.front && g_frame.w > 0) {
		int n = g_frame.pitch * g_frame.h;
		if (n > 0 && n <= g_frame.front_cap) {
			const uint8_t *src = g_frame.pixels;
			uint8_t *dst = g_frame.front;
#if defined(__APPLE__)
			/* macOS Flutter Texture → CVPixelBuffer(kCVPixelFormatType_32BGRA)
			 * 保持 libvlc RV32 的 BGRA 字节序，否则红蓝对调。 */
			memcpy(dst, src, (size_t)n);
			for (int i = 3; i < n; i += 4) {
				dst[i] = 255;
			}
#else
			/* Win/Linux Flutter PixelBuffer 要 RGBA：RV32=BGRA → 预转 RGBA */
			int i = 0;
			for (; i + 16 <= n; i += 16) {
				dst[i + 0] = src[i + 2];
				dst[i + 1] = src[i + 1];
				dst[i + 2] = src[i + 0];
				dst[i + 3] = 255;
				dst[i + 4] = src[i + 6];
				dst[i + 5] = src[i + 5];
				dst[i + 6] = src[i + 4];
				dst[i + 7] = 255;
				dst[i + 8] = src[i + 10];
				dst[i + 9] = src[i + 9];
				dst[i + 10] = src[i + 8];
				dst[i + 11] = 255;
				dst[i + 12] = src[i + 14];
				dst[i + 13] = src[i + 13];
				dst[i + 14] = src[i + 12];
				dst[i + 15] = 255;
			}
			for (; i + 3 < n; i += 4) {
				dst[i + 0] = src[i + 2];
				dst[i + 1] = src[i + 1];
				dst[i + 2] = src[i + 0];
				dst[i + 3] = 255;
			}
#endif
			g_frame.front_w = g_frame.w;
			g_frame.front_h = g_frame.h;
			g_frame.dirty = 1;
			g_frame.seq++;
			g_frame_at_ms = kotv_now_ms();
		}
	}
	FUNLOCK();
}

static unsigned format_cb(void **opaque, char *chroma,
                          unsigned *width, unsigned *height,
                          unsigned *pitches, unsigned *lines) {
	(void)opaque;
	memcpy(chroma, "RV32", 4);
	if (*width == 0)
		*width = 1280;
	if (*height == 0)
		*height = 720;
	if (frame_ensure((int)*width, (int)*height) != 0)
		return 0;
	pitches[0] = (unsigned)g_frame.pitch;
	lines[0] = *height;
	return 1;
}

static void cleanup_cb(void *opaque) {
	(void)opaque;
}

static void on_vlc_event(const libvlc_event_t *ev, void *opaque) {
	(void)opaque;
	if (!ev) return;
	switch (ev->type) {
	case KOTV_VLC_EVENT_BUFFERING: {
		float c = ev->u.media_player_buffering.new_cache;
		if (c < 0.f) c = 0.f;
		if (c > 100.f) c = 100.f;
		g_buffer_pct = c;
		g_buffer_at_ms = kotv_now_ms();
		break;
	}
	case KOTV_VLC_EVENT_PLAYING:
		/* 已恢复播放：清掉残留的 <100% 事件，避免一直显示"缓冲中" */
		g_buffer_pct = 100.f;
		g_buffer_at_ms = 0;
		break;
	case KOTV_VLC_EVENT_PAUSED:
	case KOTV_VLC_EVENT_STOPPED:
		g_buffer_at_ms = 0;
		break;
	default:
		break;
	}
}

static void attach_callbacks(void) {
	if (!g_mp)
		return;
	p_set_callbacks(g_mp, lock_cb, unlock_cb, display_cb, NULL);
	p_set_format_callbacks(g_mp, format_cb, cleanup_cb);
	if (p_mp_event_manager && p_event_attach) {
		libvlc_event_manager_t *em = p_mp_event_manager(g_mp);
		if (em) {
			p_event_attach(em, KOTV_VLC_EVENT_BUFFERING, on_vlc_event, NULL);
			p_event_attach(em, KOTV_VLC_EVENT_PLAYING, on_vlc_event, NULL);
			p_event_attach(em, KOTV_VLC_EVENT_PAUSED, on_vlc_event, NULL);
			p_event_attach(em, KOTV_VLC_EVENT_STOPPED, on_vlc_event, NULL);
		}
	}
}

static int bind_syms(void) {
	p_new = (fn_libvlc_new)DL_SYM(g_lib, "libvlc_new");
	p_release = (fn_libvlc_release)DL_SYM(g_lib, "libvlc_release");
	p_mp_new = (fn_libvlc_media_player_new)DL_SYM(g_lib, "libvlc_media_player_new");
	p_mp_release = (fn_libvlc_media_player_release)DL_SYM(g_lib, "libvlc_media_player_release");
	p_media_new = (fn_libvlc_media_new_location)DL_SYM(g_lib, "libvlc_media_new_location");
	p_media_release = (fn_libvlc_media_release)DL_SYM(g_lib, "libvlc_media_release");
	p_set_media = (fn_libvlc_media_player_set_media)DL_SYM(g_lib, "libvlc_media_player_set_media");
	p_play = (fn_libvlc_media_player_play)DL_SYM(g_lib, "libvlc_media_player_play");
	p_stop = (fn_libvlc_media_player_stop)DL_SYM(g_lib, "libvlc_media_player_stop");
	p_set_pause = (fn_libvlc_media_player_set_pause)DL_SYM(g_lib, "libvlc_media_player_set_pause");
	p_is_playing = (fn_libvlc_media_player_is_playing)DL_SYM(g_lib, "libvlc_media_player_is_playing");
	p_get_state = (fn_libvlc_media_player_get_state)DL_SYM(g_lib, "libvlc_media_player_get_state");
	p_set_time = (fn_libvlc_media_player_set_time)DL_SYM(g_lib, "libvlc_media_player_set_time");
	p_get_time = (fn_libvlc_media_player_get_time)DL_SYM(g_lib, "libvlc_media_player_get_time");
	p_get_length = (fn_libvlc_media_player_get_length)DL_SYM(g_lib, "libvlc_media_player_get_length");
	p_set_volume = (fn_libvlc_audio_set_volume)DL_SYM(g_lib, "libvlc_audio_set_volume");
	p_set_callbacks = (fn_libvlc_video_set_callbacks)DL_SYM(g_lib, "libvlc_video_set_callbacks");
	p_set_format_callbacks = (fn_libvlc_video_set_format_callbacks)DL_SYM(g_lib, "libvlc_video_set_format_callbacks");
	if (!p_new || !p_release || !p_mp_new || !p_mp_release || !p_media_new || !p_media_release ||
	    !p_set_media || !p_play || !p_stop || !p_set_pause || !p_is_playing || !p_set_time ||
	    !p_get_time || !p_get_length || !p_set_volume || !p_set_callbacks || !p_set_format_callbacks)
		return -1;

	/* 可选扩展符号：缺失不影响基础播放 */
	p_set_hwnd = (fn_libvlc_media_player_set_hwnd)DL_SYM(g_lib, "libvlc_media_player_set_hwnd");
	p_set_nsobject = (fn_libvlc_media_player_set_nsobject)DL_SYM(g_lib, "libvlc_media_player_set_nsobject");
	p_set_xwindow = (fn_libvlc_media_player_set_xwindow)DL_SYM(g_lib, "libvlc_media_player_set_xwindow");
	p_set_rate = (fn_libvlc_media_player_set_rate)DL_SYM(g_lib, "libvlc_media_player_set_rate");
	p_get_rate = (fn_libvlc_media_player_get_rate)DL_SYM(g_lib, "libvlc_media_player_get_rate");
	p_video_get_size = (fn_libvlc_video_get_size)DL_SYM(g_lib, "libvlc_video_get_size");
	p_audio_desc = (fn_track_desc)DL_SYM(g_lib, "libvlc_audio_get_track_description");
	p_spu_desc = (fn_track_desc)DL_SYM(g_lib, "libvlc_video_get_spu_description");
	p_track_release = (fn_track_desc_release)DL_SYM(g_lib, "libvlc_track_description_list_release");
	p_audio_get = (fn_track_get)DL_SYM(g_lib, "libvlc_audio_get_track");
	p_audio_set = (fn_track_set)DL_SYM(g_lib, "libvlc_audio_set_track");
	p_spu_get = (fn_track_get)DL_SYM(g_lib, "libvlc_video_get_spu");
	p_spu_set = (fn_track_set)DL_SYM(g_lib, "libvlc_video_set_spu");
	p_add_slave = (fn_add_slave)DL_SYM(g_lib, "libvlc_media_player_add_slave");
	p_set_spu_delay = (fn_set_spu_delay)DL_SYM(g_lib, "libvlc_video_set_spu_delay");
	p_media_add_option = (fn_media_add_option)DL_SYM(g_lib, "libvlc_media_add_option");
	p_mp_event_manager = (fn_mp_event_manager)DL_SYM(g_lib, "libvlc_media_player_event_manager");
	p_event_attach = (fn_event_attach)DL_SYM(g_lib, "libvlc_event_attach");
	p_mp_get_media = (fn_mp_get_media)DL_SYM(g_lib, "libvlc_media_player_get_media");
	p_media_get_stats = (fn_media_get_stats)DL_SYM(g_lib, "libvlc_media_get_stats");
	return 0;
}

static void path_join(char *out, size_t n, const char *a, const char *b) {
	size_t la = strlen(a);
	int need_sep = la > 0 && a[la - 1] != '/' && a[la - 1] != '\\';
	if (need_sep)
		snprintf(out, n, "%s/%s", a, b);
	else
		snprintf(out, n, "%s%s", a, b);
}

int kotv_vlc_load(const char *lib_dir, const char *plugin_dir) {
	flock_init();
	if (g_lib)
		return 0;
	if (!lib_dir || !lib_dir[0])
		return -1;

#if defined(_WIN32)
	{
		int n = MultiByteToWideChar(CP_UTF8, 0, lib_dir, -1, NULL, 0);
		if (n > 0) {
			wchar_t *w = (wchar_t *)malloc((size_t)n * sizeof(wchar_t));
			if (w && MultiByteToWideChar(CP_UTF8, 0, lib_dir, -1, w, n) > 0)
				SetDllDirectoryW(w);
			free(w);
		}
	}
#endif

	char path[1024];
#if defined(_WIN32)
	path_join(path, sizeof(path), lib_dir, "libvlccore.dll");
	g_libcore = DL_OPEN(path);
	path_join(path, sizeof(path), lib_dir, "libvlc.dll");
	g_lib = DL_OPEN(path);
#elif defined(__APPLE__)
	path_join(path, sizeof(path), lib_dir, "libvlccore.dylib");
	g_libcore = DL_OPEN(path);
	path_join(path, sizeof(path), lib_dir, "libvlc.dylib");
	g_lib = DL_OPEN(path);
	if (!g_lib) {
		path_join(path, sizeof(path), lib_dir, "libvlc.5.dylib");
		g_lib = DL_OPEN(path);
	}
#else
	path_join(path, sizeof(path), lib_dir, "libvlccore.so.9");
	g_libcore = DL_OPEN(path);
	if (!g_libcore) {
		path_join(path, sizeof(path), lib_dir, "libvlccore.so");
		g_libcore = DL_OPEN(path);
	}
	path_join(path, sizeof(path), lib_dir, "libvlc.so.5");
	g_lib = DL_OPEN(path);
	if (!g_lib) {
		path_join(path, sizeof(path), lib_dir, "libvlc.so");
		g_lib = DL_OPEN(path);
	}
#endif
	if (!g_lib)
		return -2;
	if (bind_syms() != 0) {
		DL_CLOSE(g_lib);
		g_lib = NULL;
		return -3;
	}

	if (plugin_dir && plugin_dir[0]) {
#if defined(_WIN32)
		{
			int n = MultiByteToWideChar(CP_UTF8, 0, plugin_dir, -1, NULL, 0);
			if (n > 0) {
				wchar_t *w = (wchar_t *)malloc((size_t)n * sizeof(wchar_t));
				if (w && MultiByteToWideChar(CP_UTF8, 0, plugin_dir, -1, w, n) > 0)
					SetEnvironmentVariableW(L"VLC_PLUGIN_PATH", w);
				free(w);
			}
		}
#else
		setenv("VLC_PLUGIN_PATH", plugin_dir, 1);
#endif
	}

	/* VLC 仅暴露时间缓存；按物理内存算字节预算，再换算成 ms（按 ~16Mbps≈2MB/s），
	 * 使 4K/8K 不会因固定超长 network-caching 占满内存。 */
	int64_t phys = 0;
#if defined(_WIN32)
	MEMORYSTATUSEX ms;
	ms.dwLength = sizeof(ms);
	if (GlobalMemoryStatusEx(&ms))
		phys = (int64_t)ms.ullTotalPhys;
#elif defined(__APPLE__)
	{
		int mib[2] = {CTL_HW, HW_MEMSIZE};
		uint64_t mem = 0;
		size_t len = sizeof(mem);
		if (sysctl(mib, 2, &mem, &len, NULL, 0) == 0)
			phys = (int64_t)mem;
	}
#else
	{
		long pages = sysconf(_SC_PHYS_PAGES);
		long psize = sysconf(_SC_PAGESIZE);
		if (pages > 0 && psize > 0)
			phys = (int64_t)pages * (int64_t)psize;
	}
#endif
	if (phys <= 0)
		phys = (int64_t)8 * 1024 * 1024 * 1024;
	int64_t budget = (int64_t)(phys * 0.05);
	{
		const int64_t min_b = (int64_t)48 * 1024 * 1024;
		const int64_t max_b = (int64_t)384 * 1024 * 1024;
		if (budget < min_b)
			budget = min_b;
		if (budget > max_b)
			budget = max_b;
	}
	/* ms ≈ budget / 2MB/s；钳到 1.5s–60s */
	int cache_ms = (int)((budget * 1000) / ((int64_t)2 * 1024 * 1024));
	if (cache_ms < 1500)
		cache_ms = 1500;
	if (cache_ms > 60000)
		cache_ms = 60000;
	g_cache_ms = cache_ms;

	static char net_arg[48];
	static char file_arg[48];
	snprintf(net_arg, sizeof(net_arg), "--network-caching=%d", cache_ms);
	snprintf(file_arg, sizeof(file_arg), "--file-caching=%d", cache_ms);

	const char *args[] = {
	    "--no-video-title-show",
	    "--quiet",
	    "--no-osd",
	    /* libvlc_media_get_stats 依赖统计开启，否则读不到下载字节数（网速恒 0） */
	    "--stats",
	    net_arg,
	    file_arg,
	    "--live-caching=1500",
	    "--clock-jitter=0",
	    "--drop-late-frames",
	    "--skip-frames",
	};
	g_inst = p_new((int)(sizeof(args) / sizeof(args[0])), args);
	if (!g_inst)
		return -4;
	g_mp = p_mp_new(g_inst);
	if (!g_mp)
		return -5;

	attach_callbacks();
	frame_ensure(1280, 720);
	return 0;
}

void kotv_vlc_unload(void) {
	if (g_mp) {
		p_stop(g_mp);
		p_mp_release(g_mp);
		g_mp = NULL;
	}
	if (g_inst) {
		p_release(g_inst);
		g_inst = NULL;
	}
	g_hard = 0;
	g_hwnd = NULL;
	frame_free();
	if (g_lib) {
		DL_CLOSE(g_lib);
		g_lib = NULL;
	}
	if (g_libcore) {
		DL_CLOSE(g_libcore);
		g_libcore = NULL;
	}
	p_new = NULL;
	p_set_hwnd = NULL;
	p_set_nsobject = NULL;
	p_set_xwindow = NULL;
}

int kotv_vlc_loaded(void) {
	return g_lib && g_inst && g_mp ? 1 : 0;
}

static int kotv_strncasecmp(const char *a, const char *b, size_t n) {
#if defined(_WIN32)
	return _strnicmp(a, b, n);
#else
	return strncasecmp(a, b, n);
#endif
}

/* 把 "Key: Value" 行写成 libvlc media 选项（需要 Referer/UA 的直播否则会一直缓冲）。 */
static void kotv_vlc_apply_http_header_line(libvlc_media_t *media, const char *line) {
	char opt[1024];
	const char *colon;
	size_t klen;
	const char *val;
	if (!media || !p_media_add_option || !line || !line[0])
		return;
	while (*line == ' ' || *line == '\t')
		line++;
	colon = strchr(line, ':');
	if (!colon || colon == line)
		return;
	klen = (size_t)(colon - line);
	val = colon + 1;
	while (*val == ' ' || *val == '\t')
		val++;
	if (!val[0] || klen == 0 || klen > 128)
		return;
	if (klen == 10 && kotv_strncasecmp(line, "User-Agent", 10) == 0) {
		snprintf(opt, sizeof(opt), ":http-user-agent=%s", val);
		p_media_add_option(media, opt);
		return;
	}
	if ((klen == 7 && kotv_strncasecmp(line, "Referer", 7) == 0) ||
	    (klen == 8 && kotv_strncasecmp(line, "Referrer", 8) == 0)) {
		snprintf(opt, sizeof(opt), ":http-referrer=%s", val);
		p_media_add_option(media, opt);
		return;
	}
	if (klen == 6 && kotv_strncasecmp(line, "Cookie", 6) == 0) {
		snprintf(opt, sizeof(opt), ":http-cookie=%s", val);
		p_media_add_option(media, opt);
		return;
	}
	/* 其余头走 extra-headers；libvlc 允许重复追加 */
	if (klen + strlen(val) + 24 >= sizeof(opt))
		return;
	snprintf(opt, sizeof(opt), ":http-extra-headers=%.*s: %s", (int)klen, line, val);
	p_media_add_option(media, opt);
}

static void kotv_vlc_apply_http_headers(libvlc_media_t *media, const char *headers_crlf) {
	char buf[4096];
	char *p;
	char *nl;
	size_t n;
	if (!media || !headers_crlf || !headers_crlf[0])
		return;
	n = strlen(headers_crlf);
	if (n >= sizeof(buf))
		n = sizeof(buf) - 1;
	memcpy(buf, headers_crlf, n);
	buf[n] = 0;
	p = buf;
	while (p && *p) {
		nl = strchr(p, '\n');
		if (nl) {
			*nl = 0;
			if (nl > p && nl[-1] == '\r')
				nl[-1] = 0;
		}
		kotv_vlc_apply_http_header_line(media, p);
		p = nl ? nl + 1 : NULL;
	}
}

int kotv_vlc_play(const char *mrl) {
	return kotv_vlc_play_with_headers(mrl, NULL);
}

int kotv_vlc_play_with_headers(const char *mrl, const char *headers_crlf) {
	if (!g_mp || !g_inst || !mrl)
		return -1;
	p_stop(g_mp);
	g_frame.dirty = 0;
	g_frame_at_ms = 0;
	g_buffer_pct = 0.f;
	g_buffer_at_ms = 0;
	g_speed_last_bytes = -1;
	g_speed_last_at_ms = 0;
	g_speed_bps = 0;
	g_pos_last_ms = -1;
	g_pos_last_at_ms = 0;
	libvlc_media_t *media = p_media_new(g_inst, mrl);
	if (!media)
		return -2;
	/* soft/hard 按设置下发；auto(g_soft_decode<0) 不附加，交给 libvlc 默认。
	 * 纹理回调路径硬解走 avcodec-hw=any（可 download 到系统内存出帧）。 */
	if (g_soft_decode >= 0 && p_media_add_option)
		p_media_add_option(media, g_soft_decode ? ":avcodec-hw=none" : ":avcodec-hw=any");
	kotv_vlc_apply_http_headers(media, headers_crlf);
	/* 单集无限循环（TV REPEAT_MODE_ONE）；极大次数近似无限 */
	if (g_repeat_one && p_media_add_option)
		p_media_add_option(media, ":input-repeat=999999");
	p_set_media(g_mp, media);
	p_media_release(media);
	if (p_play(g_mp) != 0)
		return -3;
	return 0;
}

int kotv_vlc_set_decode(int soft) {
	/* soft<0 = 自动（不附加 media 选项，保持 libvlc 默认）
	 * soft=1 软解 / soft=0 硬解。页内 RGBA 回调路径下硬解可能无帧，调用方应谨慎。 */
	if (soft < 0) {
		g_soft_decode = -1;
		return 0;
	}
	g_soft_decode = soft ? 1 : 0;
	return 0;
}

int kotv_vlc_can_decode(void) {
	return p_media_add_option != NULL;
}

void kotv_vlc_set_repeat(int on) {
	g_repeat_one = on ? 1 : 0;
}

int kotv_vlc_get_repeat(void) {
	return g_repeat_one;
}

void kotv_vlc_stop(void) {
	if (g_mp)
		p_stop(g_mp);
	g_frame.dirty = 0;
	g_buffer_at_ms = 0;
	g_speed_last_bytes = -1;
	g_speed_bps = 0;
}

void kotv_vlc_pause(int do_pause) {
	if (g_mp)
		p_set_pause(g_mp, do_pause);
}

int kotv_vlc_is_playing(void) {
	if (!g_mp)
		return 0;
	return p_is_playing(g_mp);
}

int kotv_vlc_get_state(void) {
	if (!g_mp || !p_get_state)
		return -1;
	return p_get_state(g_mp);
}

int kotv_vlc_ended(void) {
	/* libvlc_Ended == 6，对齐 ExoPlayer STATE_ENDED */
	return kotv_vlc_get_state() == 6;
}

void kotv_vlc_set_time(int64_t ms) {
	if (g_mp)
		p_set_time(g_mp, ms);
}

int64_t kotv_vlc_get_time(void) {
	if (!g_mp)
		return 0;
	return p_get_time(g_mp);
}

int64_t kotv_vlc_get_length(void) {
	if (!g_mp)
		return 0;
	return p_get_length(g_mp);
}

/* 缓冲事件是否仍新鲜；libvlc 稳定播放时不再发事件，陈旧值不可当现状 */
static int buffer_event_fresh(void) {
	int64_t at = g_buffer_at_ms;
	if (at <= 0)
		return 0;
	int64_t age = kotv_now_ms() - at;
	return (age >= 0 && age <= 1200) ? 1 : 0;
}

int64_t kotv_vlc_get_buffered(void) {
	if (!g_mp)
		return 0;
	int64_t t = p_get_time(g_mp);
	int64_t len = p_get_length(g_mp);
	if (len <= t)
		return t;
	/* libvlc 不暴露 demux 缓冲时长：用实际下发的 network-caching 作窗口估算。
	 * 正在补缓冲时按事件百分比缩放，避免进度条虚报成"整集已缓冲"。 */
	int64_t win = (int64_t)g_cache_ms;
	if (win < 1000)
		win = 1000;
	if (buffer_event_fresh()) {
		double pct = (double)g_buffer_pct;
		if (pct < 0.0)
			pct = 0.0;
		if (pct > 100.0)
			pct = 100.0;
		win = (int64_t)((double)win * pct / 100.0);
	}
	int64_t end = t + win;
	return end > len ? len : end;
}

/* 缓冲中 = libvlc_Buffering，或「点播 Playing 且进度卡住且有新鲜 cache」。
 * 直播（length<=0）Playing 时不要因 time 不动误判永久缓冲；有近期帧则更不算。 */
int kotv_vlc_is_buffering(void) {
	if (!g_mp || !p_get_state)
		return 0;

	int64_t now = kotv_now_ms();
	int st = p_get_state(g_mp);
	if (st == 2) /* libvlc_Buffering */
		return 1;

	/* 近期有解码帧 → 已出画 */
	if (g_frame_at_ms > 0 && (now - g_frame_at_ms) < 1200)
		return 0;

	if (st != 3 || !p_is_playing(g_mp)) /* 非 Playing */
		return 0;

	int64_t len = p_get_length ? p_get_length(g_mp) : 0;
	/* 直播/无限流：Playing 即视为在播，不再用进度卡住+cache 事件误报 */
	if (len <= 0)
		return 0;

	int64_t t = p_get_time(g_mp);
	if (t != g_pos_last_ms) {
		g_pos_last_ms = t;
		g_pos_last_at_ms = now;
	}
	int stalled = (g_pos_last_at_ms <= 0) || (now - g_pos_last_at_ms) >= 700;
	if (!buffer_event_fresh() || g_buffer_pct >= 99.5f)
		return 0;
	return stalled ? 1 : 0;
}

/* 下载速度（字节/秒）。
 * 优先用累计 i_read_bytes 自行差分：不依赖 libvlc 内部码率的单位约定。
 * 兜底才用 f_input_bitrate —— 它是 **bytes/µs**（VLC 界面按 *8000 显示 kbit/s），
 * 早期按 bits/s 处理导致永远显示 0.00 KB/s。 */
int64_t kotv_vlc_get_speed_bps(void) {
	if (!g_mp || !p_mp_get_media || !p_media_get_stats)
		return 0;
	libvlc_media_t *m = p_mp_get_media(g_mp);
	if (!m)
		return 0;
	libvlc_media_stats_t st;
	memset(&st, 0, sizeof(st));
	int ok = p_media_get_stats(m, &st);
	if (p_media_release)
		p_media_release(m);
	if (!ok)
		return g_speed_bps;

	int64_t now = kotv_now_ms();
	int64_t bytes = (int64_t)(uint32_t)st.i_read_bytes;
	if (g_speed_last_bytes >= 0 && bytes >= g_speed_last_bytes) {
		int64_t dt = now - g_speed_last_at_ms;
		if (dt >= 250) {
			int64_t delta = bytes - g_speed_last_bytes;
			/* 无增长必须归零，否则会一直显示上一帧速率 */
			g_speed_bps = delta > 0 ? (delta * 1000) / dt : 0;
			g_speed_last_bytes = bytes;
			g_speed_last_at_ms = now;
		}
	} else {
		/* 首次采样或计数回绕：只记录基准，速度清零 */
		g_speed_last_bytes = bytes;
		g_speed_last_at_ms = now;
		g_speed_bps = 0;
	}
	if (g_speed_bps > 0)
		return g_speed_bps;

	/* 根因修复：旧逻辑在建基线后把 g_speed_last_bytes>=0，却仍判断
	 * `g_speed_last_bytes < 0` 才读瞬时码率 → 兜底永不死路径，起播一直 0。
	 * 差分尚未产出有效速度时，一律用 f_*_bitrate（bytes/µs → B/s）。 */
	if (st.f_input_bitrate > 0.f)
		return (int64_t)((double)st.f_input_bitrate * 1000000.0);
	if (st.f_demux_bitrate > 0.f)
		return (int64_t)((double)st.f_demux_bitrate * 1000000.0);
	return g_speed_bps;
}

int kotv_vlc_set_volume(int vol) {
	if (!g_mp)
		return -1;
	return p_set_volume(g_mp, vol);
}

int kotv_vlc_take_frame(uint8_t *out, int out_cap, int *out_w, int *out_h) {
	if (g_hard || !out || !out_w || !out_h)
		return 0;
	FLOCK();
	int ret = 0;
	if (g_frame.dirty && g_frame.front) {
		int w = g_frame.front_w;
		int h = g_frame.front_h;
		/* size_t 避免大分辨率乘法溢出 */
		size_t n = (size_t)w * (size_t)h * 4;
		*out_w = w;
		*out_h = h;
		if (n > 0 && out_cap >= 0 && (size_t)out_cap >= n && n <= (size_t)g_frame.front_cap) {
			memcpy(out, g_frame.front, n);
			g_frame.dirty = 0;
			ret = 1;
		}
	}
	FUNLOCK();
	return ret;
}

int kotv_vlc_peek_frame(int *out_w, int *out_h, int64_t *out_seq) {
	FLOCK();
	int ok = 0;
	if (g_frame.dirty && g_frame.front && g_frame.front_w > 0 && g_frame.front_h > 0) {
		if (out_w) *out_w = g_frame.front_w;
		if (out_h) *out_h = g_frame.front_h;
		if (out_seq) *out_seq = g_frame.seq;
		ok = 1;
	} else {
		if (out_w) *out_w = g_frame.w;
		if (out_h) *out_h = g_frame.h;
		if (out_seq) *out_seq = g_frame.seq;
	}
	FUNLOCK();
	return ok;
}

int64_t kotv_vlc_frame_seq(void) {
	int64_t s;
	FLOCK();
	s = g_frame.seq;
	FUNLOCK();
	return s;
}

int kotv_vlc_set_rate(float rate) {
	if (!g_mp || !p_set_rate)
		return -1;
	return p_set_rate(g_mp, rate);
}

float kotv_vlc_get_rate(void) {
	if (!g_mp || !p_get_rate)
		return 1.0f;
	return p_get_rate(g_mp);
}

int kotv_vlc_video_size(int *w, int *h) {
	if (!g_mp || !p_video_get_size || !w || !h)
		return -1;
	unsigned uw = 0, uh = 0;
	if (p_video_get_size(g_mp, 0, &uw, &uh) != 0)
		return -2;
	*w = (int)uw;
	*h = (int)uh;
	return 0;
}

int kotv_vlc_cycle_track(int type) {
	if (!g_mp)
		return -1;
	fn_track_desc desc = type == 0 ? p_audio_desc : p_spu_desc;
	fn_track_get get = type == 0 ? p_audio_get : p_spu_get;
	fn_track_set set = type == 0 ? p_audio_set : p_spu_set;
	if (!desc || !get || !set)
		return -2;
	libvlc_track_description_t *list = desc(g_mp);
	if (!list)
		return -3;
	int cur = get(g_mp);
	int first = list->i_id;
	int next = first;
	int found = 0;
	libvlc_track_description_t *it;
	for (it = list; it; it = it->p_next) {
		if (found) {
			next = it->i_id;
			break;
		}
		if (it->i_id == cur)
			found = 1;
	}
	set(g_mp, next);
	if (p_track_release)
		p_track_release(list);
	return next;
}

int kotv_vlc_track_list(int type, char *buf, int cap) {
	if (!g_mp || !buf || cap <= 0)
		return -1;
	fn_track_desc desc = type == 0 ? p_audio_desc : p_spu_desc;
	if (!desc)
		return -2;
	libvlc_track_description_t *list = desc(g_mp);
	if (!list)
		return 0;
	int n = 0, used = 0;
	libvlc_track_description_t *it;
	for (it = list; it; it = it->p_next) {
		int wrote = snprintf(buf + used, (size_t)(cap - used), "%d\t%s\n",
		                     it->i_id, it->psz_name ? it->psz_name : "");
		if (wrote <= 0 || used + wrote >= cap)
			break;
		used += wrote;
		n++;
	}
	if (p_track_release)
		p_track_release(list);
	return n;
}

int kotv_vlc_get_track(int type) {
	if (!g_mp)
		return -1;
	fn_track_get get = type == 0 ? p_audio_get : p_spu_get;
	if (!get)
		return -2;
	return get(g_mp);
}

int kotv_vlc_set_track(int type, int id) {
	if (!g_mp)
		return -1;
	fn_track_set set = type == 0 ? p_audio_set : p_spu_set;
	if (!set)
		return -2;
	return set(g_mp, id);
}

int kotv_vlc_add_subtitle(const char *uri) {
	if (!g_mp || !uri)
		return -1;
	if (!p_add_slave)
		return -2;
	/* 0 = libvlc_media_slave_type_subtitle, select=1 */
	return p_add_slave(g_mp, 0, uri, 1);
}

int kotv_vlc_set_spu_delay(int64_t us) {
	if (!g_mp || !p_set_spu_delay)
		return -1;
	return p_set_spu_delay(g_mp, us);
}

/* 重建 media player（回收卡死/失效的解码管线），成功返回 0 */
int kotv_vlc_recreate(void) {
	if (!g_inst || !p_mp_new)
		return -1;
	if (g_mp) {
		p_stop(g_mp);
		p_mp_release(g_mp);
		g_mp = NULL;
	}
	g_mp = p_mp_new(g_inst);
	if (!g_mp)
		return -2;
	if (g_hard && g_hwnd) {
		if (p_set_hwnd)
			p_set_hwnd(g_mp, g_hwnd);
		else if (p_set_nsobject)
			p_set_nsobject(g_mp, g_hwnd);
		else if (p_set_xwindow)
			p_set_xwindow(g_mp, (uint32_t)(uintptr_t)g_hwnd);
		else {
			g_hard = 0;
			g_hwnd = NULL;
			attach_callbacks();
		}
	} else {
		g_hard = 0;
		g_hwnd = NULL;
		attach_callbacks();
	}
	FLOCK();
	g_frame.dirty = 0;
	FUNLOCK();
	return 0;
}

int kotv_vlc_can_hard_output(void) {
	return p_set_hwnd != NULL || p_set_nsobject != NULL || p_set_xwindow != NULL;
}

int kotv_vlc_hard_active(void) {
	return g_hard && g_mp ? 1 : 0;
}

int kotv_vlc_set_hard_win(long long win) {
	if (!g_inst || !p_mp_new)
		return -1;
	if (win && !kotv_vlc_can_hard_output())
		return -2;
	g_hwnd = win ? (void *)(uintptr_t)win : NULL;
	g_hard = win ? 1 : 0;
	return kotv_vlc_recreate();
}
