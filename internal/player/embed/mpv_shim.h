#ifndef KOTV_MPV_SHIM_H
#define KOTV_MPV_SHIM_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

int kotv_mpv_load(const char *lib_path);
void kotv_mpv_unload(void);
int kotv_mpv_loaded(void);
/* 须在 mpv_initialize 前设置；变更后 kotv_mpv_reinit_player() 重建实例。 */
int kotv_mpv_set_preinit_options(int gpu_next, int vulkan, const char *hwdec);
int kotv_mpv_reinit_player(void);
/* 扫描 libmpv 二进制是否含 vulkan 特性（无需完整初始化）。 */
int kotv_mpv_lib_has_vulkan(const char *lib_path);
/* JSON 数组 [{id,title,lang,codec}]；调用方 kotv_mpv_free_str 释放。 */
char *kotv_mpv_get_audio_tracks_json(void);
/* 硬渲：输出到原生窗口（Windows HWND）。win=0 表示回到软件 RGBA。成功 0。 */
int kotv_mpv_set_hard_win(long long win);
int kotv_mpv_hard_active(void);
int kotv_mpv_play(const char *url);
void kotv_mpv_stop(void);
void kotv_mpv_pause(int pause);
int kotv_mpv_is_playing(void);
/* 真正播到文件尾（属性 eof-reached） */
int kotv_mpv_eof_reached(void);
void kotv_mpv_set_time(int64_t ms);
int64_t kotv_mpv_get_time(void);
int64_t kotv_mpv_get_length(void);
int kotv_mpv_set_volume(int volume);

/* 有新画面时把 libmpv SW renderer 的 rgb0 转成 RGBA，返回 1。 */
int kotv_mpv_take_frame(uint8_t *out, int out_cap, int *out_w, int *out_h);

/* 通用属性访问：支撑倍速/画面比例/解码/音轨字幕等扩展控制。 */
int kotv_mpv_set_prop_string(const char *name, const char *value);
int kotv_mpv_set_prop_double(const char *name, double value);
int kotv_mpv_get_prop_double(const char *name, double *out);
int kotv_mpv_get_prop_int64(const char *name, int64_t *out);
int kotv_mpv_set_prop_int64(const char *name, int64_t value);
char *kotv_mpv_get_prop_string(const char *name); /* kotv_mpv_free_str 释放 */
void kotv_mpv_free_str(char *p);
int kotv_mpv_cycle(const char *prop);
int kotv_mpv_cmd2(const char *a, const char *b);

#ifdef __cplusplus
}
#endif

#endif
