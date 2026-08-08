// vlc_shim.h — libvlc 动态加载与软渲染帧缓冲（C 侧，避免 video 线程调 Go）
#ifndef KOTV_VLC_SHIM_H
#define KOTV_VLC_SHIM_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

int kotv_vlc_load(const char *lib_dir, const char *plugin_dir);
void kotv_vlc_unload(void);
int kotv_vlc_loaded(void);

int kotv_vlc_play(const char *mrl);
/* headers_crlf: 多行 "Key: Value\r\n"（可仅 \\n）；在 play 建 media 时注入 http-* 选项 */
int kotv_vlc_play_with_headers(const char *mrl, const char *headers_crlf);
void kotv_vlc_stop(void);
void kotv_vlc_pause(int do_pause);
int kotv_vlc_is_playing(void);
/* libvlc_state_t；Ended=6。符号缺失时返回 -1 */
int kotv_vlc_get_state(void);
/* 是否真正播完（libvlc_Ended） */
int kotv_vlc_ended(void);
void kotv_vlc_set_time(int64_t ms);
int64_t kotv_vlc_get_time(void);
int64_t kotv_vlc_get_length(void);
/* 已缓冲到的大致时间戳（ms）；无事件时退回当前播放位置 */
int64_t kotv_vlc_get_buffered(void);
/* Opening/Buffering 或 cache<100 */
int kotv_vlc_is_buffering(void);
/* 估算下载速度 bytes/s */
int64_t kotv_vlc_get_speed_bps(void);
int kotv_vlc_set_volume(int vol);

/* 有脏帧时：写入 *out_w、*out_h；若 out_cap>=w*h*4 则拷贝并清 dirty，返回 1。
 * 像素：Apple=BGRA，Win/Linux=RGBA。缓冲不够时仍返回尺寸、返回 0，调用方扩容后再 take。 */
int kotv_vlc_take_frame(uint8_t *out, int out_cap, int *out_w, int *out_h);

/* 已 display 的累计帧序号，watchdog 用于判断是否卡死（无新帧） */
int64_t kotv_vlc_frame_seq(void);

/* 只查尺寸/序号，不消费帧；有脏帧返回 1 */
int kotv_vlc_peek_frame(int *out_w, int *out_h, int64_t *out_seq);

/* 重建底层 media player（回收卡死/失效解码管线），成功返回 0 */
int kotv_vlc_recreate(void);
/* 硬渲：原生窗口（Win HWND / macOS NSView* / Linux XID）。win=0 回 video callbacks。成功 0。 */
int kotv_vlc_set_hard_win(long long win);
int kotv_vlc_hard_active(void);
int kotv_vlc_can_hard_output(void);

/* 扩展控制：倍速 / 视频尺寸 / 音轨字幕循环（符号缺失时返回负值）。 */
int kotv_vlc_set_rate(float rate);
float kotv_vlc_get_rate(void);
int kotv_vlc_video_size(int *w, int *h);
/* type: 0=音轨 1=字幕；返回新轨道 id，<0 失败/不支持 */
int kotv_vlc_cycle_track(int type);

/* 轨道列表：每行 "id\tname\n" 写入 buf；返回条数，<0 失败/不支持 */
int kotv_vlc_track_list(int type, char *buf, int cap);
int kotv_vlc_get_track(int type);
int kotv_vlc_set_track(int type, int id);
/* 外挂字幕（uri 形如 file:///path.srt），成功返回 0 */
int kotv_vlc_add_subtitle(const char *uri);
/* 解码方式：soft=1 软解 / soft=0 硬解，在下一次 play 建 media 时生效 */
int kotv_vlc_set_decode(int soft);
/* 本机 libvlc 是否支持按 media 设置解码选项 */
int kotv_vlc_can_decode(void);
/* 单集循环：1=开 / 0=关；下次 play 建 media 时带 :input-repeat */
void kotv_vlc_set_repeat(int on);
int kotv_vlc_get_repeat(void);
/* 字幕延迟（微秒），成功返回 0 */
int kotv_vlc_set_spu_delay(int64_t us);

#ifdef __cplusplus
}
#endif

#endif
