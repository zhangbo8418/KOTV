#ifndef KOTV_MPV_DESKTOP_CORE_H
#define KOTV_MPV_DESKTOP_CORE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef void (*kotv_mpv_desktop_event_cb)(const char* event_json, void* user);

int kotv_mpv_desktop_init(const char* lib_path);
/* 仅绑定 libmpv DLL，不 init 播放器（Windows HWND 硬渲 attach 前）。 */
int kotv_mpv_desktop_ensure_lib(const char* lib_path);
int kotv_mpv_desktop_set_hard_win(long long win);
int kotv_mpv_desktop_hard_active(void);
/* create 成功后同步渲染选项，避免 open 误判变更而强制 reinit。 */
void kotv_mpv_desktop_note_opts(int gpu_next, int vulkan);
/* 停播但保留已加载的 libmpv（供 dispose 用，避免与下一次 create 抢卸库）。 */
void kotv_mpv_desktop_release(void);
void kotv_mpv_desktop_shutdown(void);
int kotv_mpv_desktop_is_ready(void);

int kotv_mpv_desktop_is_vulkan_available(void);
char* kotv_mpv_desktop_get_audio_tracks_json(void);

int kotv_mpv_desktop_open(const char* url, const char* headers_multiline,
                          const char* hwdec, int gpu_next, int vulkan, int live);
void kotv_mpv_desktop_stop(void);
void kotv_mpv_desktop_pause(int pause);
void kotv_mpv_desktop_seek_ms(int64_t ms);
int kotv_mpv_desktop_set_volume(int vol);
int kotv_mpv_desktop_set_rate(double rate);
int kotv_mpv_desktop_set_prop(const char* key, const char* val);

/* 应用 Dart propertyMap；keys/vals 等长，跳过 vo/wid 等引擎自管键。 */
int kotv_mpv_desktop_apply_props(const char* const* keys, const char* const* vals, int n);
int kotv_mpv_desktop_set_audio_track(const char* id);
int kotv_mpv_desktop_set_subtitle_track(const char* id);
/* 对最近一次 open 的 URL 重新 loadfile（对齐 Android retryVideo）。 */
int kotv_mpv_desktop_retry_video(void);

int kotv_mpv_desktop_take_frame(uint8_t* rgba, int cap, int* w, int* h);

void kotv_mpv_desktop_set_event_cb(kotv_mpv_desktop_event_cb cb, void* user);
void kotv_mpv_desktop_tick(void);

#ifdef __cplusplus
}
#endif

#endif
