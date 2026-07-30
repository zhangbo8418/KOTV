#pragma once

#ifdef __cplusplus
extern "C" {
#endif

// 返回 0 成功；errbuf 写入错误信息。
// Windows 上 CreateJavaVM 与全部 JNI 在 C 侧专用原生线程执行；call/shutdown 经队列转发。
int kotv_jvm_start(const char *jvm_lib, const char *bridge_jar, const char *cache_dir, int proxy_port, char *errbuf, int errbuf_len);
int kotv_jvm_call(const char *json_in, char *json_out, int json_out_len, char *errbuf, int errbuf_len);
// 可从任意线程调用：AttachCurrentThread 后触发 OkHttp.cancelAll，用于打断卡住的网络调用。
int kotv_jvm_cancel_all(char *errbuf, int errbuf_len);
void kotv_jvm_shutdown(void);
int kotv_jvm_ready(void);

#ifdef __cplusplus
}
#endif
