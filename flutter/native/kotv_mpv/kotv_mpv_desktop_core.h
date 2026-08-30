#ifndef KOTV_MPV_DESKTOP_CORE_H
#define KOTV_MPV_DESKTOP_CORE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef void (*kotv_mpv_desktop_event_cb)(const char* event_json, void* user);

int kotv_mpv_desktop_init(const char* lib_path);
void kotv_mpv_desktop_shutdown(void);
int kotv_mpv_desktop_is_ready(void);

int kotv_mpv_desktop_open(const char* url, const char* headers_multiline,
                          const char* hwdec, int gpu_next, int vulkan, int live);
void kotv_mpv_desktop_stop(void);
void kotv_mpv_desktop_pause(int pause);
void kotv_mpv_desktop_seek_ms(int64_t ms);
int kotv_mpv_desktop_set_volume(int vol);
int kotv_mpv_desktop_set_rate(double rate);
int kotv_mpv_desktop_set_prop(const char* key, const char* val);

int kotv_mpv_desktop_take_frame(uint8_t* rgba, int cap, int* w, int* h);

void kotv_mpv_desktop_set_event_cb(kotv_mpv_desktop_event_cb cb, void* user);
void kotv_mpv_desktop_tick(void);

#ifdef __cplusplus
}
#endif

#endif
