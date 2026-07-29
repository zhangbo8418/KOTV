#pragma once

#ifdef __cplusplus
extern "C" {
#endif

/* sid 用 unsigned long long，避免依赖 stdint / gopls 对 uint64_t 的解析问题。 */
int kotv_embedpy_init(const char *py_lib, const char *py_home, char *errbuf, int errbuf_len);
unsigned long long kotv_embedpy_start(const char *bootstrap_code, char *errbuf, int errbuf_len);
int kotv_embedpy_call(unsigned long long sid, const char *json_line, char *json_out, int json_out_len, char *errbuf, int errbuf_len);
void kotv_embedpy_stop(unsigned long long sid);
void kotv_embedpy_shutdown(void);

#ifdef __cplusplus
}
#endif
