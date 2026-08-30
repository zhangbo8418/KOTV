#include "kotv_mpv_desktop_core.h"

#include "../../../internal/player/embed/mpv_shim.h"

#include <stdio.h>
#include <string.h>

static kotv_mpv_desktop_event_cb g_event_cb;
static void* g_event_user;
static int g_last_w;
static int g_last_h;
static int g_volume = 80;
static double g_rate = 1.0;

static void emit(const char* json) {
  if (g_event_cb && json) {
    g_event_cb(json, g_event_user);
  }
}

int kotv_mpv_desktop_init(const char* lib_path) {
  if (!lib_path || !lib_path[0]) return -1;
  if (kotv_mpv_loaded()) return 0;
  const int rc = kotv_mpv_load(lib_path);
  if (rc != 0) return rc;
  kotv_mpv_set_volume(g_volume);
  return 0;
}

void kotv_mpv_desktop_shutdown(void) {
  kotv_mpv_unload();
  g_last_w = 0;
  g_last_h = 0;
}

int kotv_mpv_desktop_is_ready(void) {
  return kotv_mpv_loaded();
}

int kotv_mpv_desktop_open(const char* url, const char* headers_multiline,
                          const char* hwdec, int gpu_next, int vulkan, int live) {
  (void)gpu_next;
  (void)vulkan;
  (void)live;
  if (!kotv_mpv_loaded() || !url || !url[0]) return -1;
  if (hwdec && hwdec[0]) {
    kotv_mpv_set_prop_string("hwdec", hwdec);
  }
  if (headers_multiline && headers_multiline[0]) {
    kotv_mpv_set_prop_string("http-header-fields", headers_multiline);
  }
  kotv_mpv_set_volume(g_volume);
  if (g_rate > 0.0) {
    kotv_mpv_set_prop_double("speed", g_rate);
  }
  kotv_mpv_set_prop_string("ytdl", "no");
  if (!live) {
    kotv_mpv_set_prop_string("cache", "yes");
  }
  const int rc = kotv_mpv_play(url);
  if (rc >= 0) {
    char buf[128];
    snprintf(buf, sizeof(buf), "{\"event\":\"ready\",\"width\":%d,\"height\":%d}", g_last_w, g_last_h);
    emit(buf);
  }
  return rc;
}

void kotv_mpv_desktop_stop(void) {
  if (!kotv_mpv_loaded()) return;
  kotv_mpv_set_volume(0);
  kotv_mpv_pause(1);
  kotv_mpv_stop();
}

void kotv_mpv_desktop_pause(int pause) {
  if (!kotv_mpv_loaded()) return;
  kotv_mpv_pause(pause ? 1 : 0);
}

void kotv_mpv_desktop_seek_ms(int64_t ms) {
  if (!kotv_mpv_loaded()) return;
  kotv_mpv_set_time(ms);
}

int kotv_mpv_desktop_set_volume(int vol) {
  g_volume = vol;
  if (!kotv_mpv_loaded()) return 0;
  return kotv_mpv_set_volume(vol);
}

int kotv_mpv_desktop_set_rate(double rate) {
  g_rate = rate;
  if (!kotv_mpv_loaded()) return 0;
  return kotv_mpv_set_prop_double("speed", rate);
}

int kotv_mpv_desktop_set_prop(const char* key, const char* val) {
  if (!kotv_mpv_loaded() || !key || !val) return -1;
  if (strcmp(key, "hwdec") == 0 || strcmp(key, "vo") == 0 || strcmp(key, "wid") == 0) {
    return 0;
  }
  return kotv_mpv_set_prop_string(key, val);
}

int kotv_mpv_desktop_take_frame(uint8_t* rgba, int cap, int* w, int* h) {
  if (!rgba || !w || !h) return 0;
  return kotv_mpv_take_frame(rgba, cap, w, h);
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
  if (!kotv_mpv_loaded()) return;
  const int64_t pos = kotv_mpv_get_time();
  const int64_t dur = kotv_mpv_get_length();
  const int playing = kotv_mpv_is_playing();
  if (kotv_mpv_eof_reached()) {
    emit("{\"event\":\"completed\"}");
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
}
