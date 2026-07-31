#pragma once

#ifdef __cplusplus
extern "C" {
#endif

// Windows 上 CreateJavaVM 在原生 boot worker；CALL 经有界队列由 N 个 Win32 worker 并行 JNI。
// cancelAll 旁路独立线程 Attach，不占用 CALL 队列。
int kotv_jvm_start(const char *jvm_lib, const char *bridge_jar, const char *cache_dir, int proxy_port, char *errbuf, int errbuf_len);
int kotv_jvm_call(const char *json_in, char *json_out, int json_out_len, char *errbuf, int errbuf_len);
// 可从任意线程调用：AttachCurrentThread 后触发 OkHttp.cancelAll，用于打断卡住的网络调用。
int kotv_jvm_cancel_all(char *errbuf, int errbuf_len);
void kotv_jvm_shutdown(void);
int kotv_jvm_ready(void);

#ifdef __cplusplus
}
#endif
