#ifndef KOTV_MPV_LIB_PATH_H
#define KOTV_MPV_LIB_PATH_H

#ifdef __cplusplus
extern "C" {
#endif

// Returns heap-allocated UTF-8 path or NULL. Caller must free().
char* kotv_find_libmpv_path(void);

#ifdef __cplusplus
}
#endif

#endif
