#include "kotv_mpv_desktop_core.h"

#include "../../../internal/player/embed/mpv_shim.h"
#include "kotv_mpv_lib_path.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#if defined(_WIN32)
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
static CRITICAL_SECTION g_lock;
static volatile LONG g_lock_state;
static void kotv_lock_init(void) {
  LONG prev = InterlockedCompareExchange(&g_lock_state, 1, 0);
  if (prev == 0) {
    InitializeCriticalSection(&g_lock);
    InterlockedExchange(&g_lock_state, 2);
  } else {
    while (InterlockedCompareExchange(&g_lock_state, 2, 2) != 2) {
      Sleep(0);
    }
  }
}
static void kotv_lock(void) {
  kotv_lock_init();
  EnterCriticalSection(&g_lock);
}
static void kotv_unlock(void) { LeaveCriticalSection(&g_lock); }
#else
#include <pthread.h>
static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;
static void kotv_lock(void) { pthread_mutex_lock(&g_lock); }
static void kotv_unlock(void) { pthread_mutex_unlock(&g_lock); }
#endif

static kotv_mpv_desktop_event_cb g_event_cb;
static void* g_event_user;
static int g_last_w;
static int g_last_h;
static int g_volume = 80;
static double g_rate = 1.0;
static int g_gpu_next;
static int g_vulkan;
static char g_lib_path[1024];

static void emit(const char* json) {
  if (g_event_cb && json) {
    g_event_cb(json, g_event_user);
  }
}

int kotv_mpv_desktop_init(const char* lib_path) {
  if (!lib_path || !lib_path[0]) return -1;
  kotv_lock();
  {
    size_t n = strlen(lib_path);
    if (n >= sizeof(g_lib_path)) n = sizeof(g_lib_path) - 1;
    memcpy(g_lib_path, lib_path, n);
    g_lib_path[n] = '\0';
  }
  if (kotv_mpv_loaded()) {
    kotv_unlock();
    return 0;
  }
  const int rc = kotv_mpv_load(lib_path);
  if (rc == 0) kotv_mpv_set_volume(g_volume);
  kotv_unlock();
  return rc;
}

void kotv_mpv_desktop_shutdown(void) {
  kotv_lock();
  kotv_mpv_unload();
  g_last_w = 0;
  g_last_h = 0;
  g_lib_path[0] = '\0';
  kotv_unlock();
}

int kotv_mpv_desktop_is_ready(void) {
  kotv_lock();
  const int ok = kotv_mpv_loaded();
  kotv_unlock();
  return ok;
}

int kotv_mpv_desktop_is_vulkan_available(void) {
  char path[1024];
  kotv_lock();
  snprintf(path, sizeof(path), "%s", g_lib_path);
  kotv_unlock();
  if (path[0]) return kotv_mpv_lib_has_vulkan(path);
  char* lib = kotv_find_libmpv_path();
  if (!lib) return 0;
  const int ok = kotv_mpv_lib_has_vulkan(lib);
  free(lib);
  return ok;
}

char* kotv_mpv_desktop_get_audio_tracks_json(void) {
  kotv_lock();
  char* json = kotv_mpv_get_audio_tracks_json();
  kotv_unlock();
  return json;
}

int kotv_mpv_desktop_open(const char* url, const char* headers_multiline,
                          const char* hwdec, int gpu_next, int vulkan, int live) {
  if (!url || !url[0]) return -1;
  if (kotv_mpv_os_win7()) {
    gpu_next = 0;
    vulkan = 0;
  }
  kotv_lock();
  if (!kotv_mpv_loaded()) {
    kotv_unlock();
    return -1;
  }

  const int opts_changed = (g_gpu_next != (gpu_next ? 1 : 0)) || (g_vulkan != (vulkan ? 1 : 0));
  g_gpu_next = gpu_next ? 1 : 0;
  g_vulkan = vulkan ? 1 : 0;

  kotv_mpv_set_preinit_options(g_gpu_next, g_vulkan, hwdec);
  if (opts_changed) {
    if (kotv_mpv_reinit_player() < 0) {
      g_gpu_next = 0;
      g_vulkan = 0;
      kotv_mpv_set_preinit_options(0, 0, hwdec);
      if (kotv_mpv_reinit_player() < 0) {
        kotv_unlock();
        return -2;
      }
    }
  } else if (hwdec && hwdec[0]) {
    kotv_mpv_set_prop_string("hwdec", hwdec);
  }
  if (!kotv_mpv_loaded()) {
    kotv_unlock();
    return -1;
  }

  if (headers_multiline && headers_multiline[0]) {
    kotv_mpv_set_prop_string("http-header-fields", headers_multiline);
  }
  kotv_mpv_set_volume(g_volume);
  if (g_rate > 0.0) {
    kotv_mpv_set_prop_double("speed", g_rate);
  }
  kotv_mpv_set_prop_string("ytdl", "no");
  if (!live && !kotv_mpv_os_win7()) {
    kotv_mpv_set_prop_string("cache", "yes");
  }

  const int rc = kotv_mpv_play(url);
  if (rc >= 0) {
    char buf[128];
    snprintf(buf, sizeof(buf), "{\"event\":\"ready\",\"width\":%d,\"height\":%d}", g_last_w, g_last_h);
    emit(buf);
  }
  kotv_unlock();
  return rc;
}

void kotv_mpv_desktop_stop(void) {
  kotv_lock();
  if (kotv_mpv_loaded()) {
    kotv_mpv_set_volume(0);
    kotv_mpv_pause(1);
    kotv_mpv_stop();
  }
  kotv_unlock();
}

void kotv_mpv_desktop_pause(int pause) {
  kotv_lock();
  if (kotv_mpv_loaded()) kotv_mpv_pause(pause ? 1 : 0);
  kotv_unlock();
}

void kotv_mpv_desktop_seek_ms(int64_t ms) {
  kotv_lock();
  if (kotv_mpv_loaded()) kotv_mpv_set_time(ms);
  kotv_unlock();
}

int kotv_mpv_desktop_set_volume(int vol) {
  g_volume = vol;
  kotv_lock();
  const int rc = kotv_mpv_loaded() ? kotv_mpv_set_volume(vol) : 0;
  kotv_unlock();
  return rc;
}

int kotv_mpv_desktop_set_rate(double rate) {
  g_rate = rate;
  kotv_lock();
  const int rc = kotv_mpv_loaded() ? kotv_mpv_set_prop_double("speed", rate) : 0;
  kotv_unlock();
  return rc;
}

int kotv_mpv_desktop_set_prop(const char* key, const char* val) {
  if (!key || !val) return -1;
  if (strcmp(key, "wid") == 0 || strcmp(key, "android-surface-size") == 0) return 0;
  if (kotv_mpv_os_win7()) {
    if (strcmp(key, "vo") == 0 || strcmp(key, "gpu-api") == 0 || strcmp(key, "gpu-context") == 0 ||
        strcmp(key, "gpu-next") == 0) {
      return 0;
    }
    if (strcmp(key, "hwdec") == 0 && strcmp(val, "dxva2") != 0 && strcmp(val, "dxva2-copy") != 0 &&
        strcmp(val, "no") != 0) {
      val = "no";
    }
  }
  kotv_lock();
  const int rc = kotv_mpv_loaded() ? kotv_mpv_set_prop_string(key, val) : -1;
  kotv_unlock();
  return rc;
}

int kotv_mpv_desktop_take_frame(uint8_t* rgba, int cap, int* w, int* h) {
  if (!rgba || !w || !h) return 0;
  kotv_lock();
  const int rc = kotv_mpv_take_frame(rgba, cap, w, h);
  kotv_unlock();
  return rc;
}

static int rgba_probe(int* w, int* h) {
  if (!w || !h) return 0;
  uint8_t tmp[16 * 16 * 4];
  return kotv_mpv_take_frame(tmp, (int)sizeof(tmp), w, h);
}

void kotv_mpv_desktop_set_event_cb(kotv_mpv_desktop_event_cb cb, void* user) {
  g_event_cb = cb;
  g_event_user = user;
}

void kotv_mpv_desktop_tick(void) {
  kotv_lock();
  if (!kotv_mpv_loaded()) {
    kotv_unlock();
    return;
  }
  const int64_t pos = kotv_mpv_get_time();
  const int64_t dur = kotv_mpv_get_length();
  const int playing = kotv_mpv_is_playing();
  if (kotv_mpv_eof_reached()) {
    emit("{\"event\":\"completed\"}");
    kotv_unlock();
    return;
  }
  char buf[256];
  snprintf(buf, sizeof(buf),
           "{\"event\":\"position\",\"positionMs\":%lld,\"durationMs\":%lld,"
           "\"bufferedMs\":%lld,\"playing\":%s,\"buffering\":false,\"speedBps\":0}",
           (long long)pos, (long long)dur, (long long)pos, playing ? "true" : "false");
  emit(buf);
  int fw = 0;
  int fh = 0;
  if (rgba_probe(&fw, &fh)) {
    if (fw != g_last_w || fh != g_last_h) {
      g_last_w = fw;
      g_last_h = fh;
      snprintf(buf, sizeof(buf), "{\"event\":\"size\",\"width\":%d,\"height\":%d}", fw, fh);
      emit(buf);
    }
  }
  kotv_unlock();
}
