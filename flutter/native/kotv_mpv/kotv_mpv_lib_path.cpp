#include "kotv_mpv_lib_path.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define KOTV_PATH_MAX 1024

static char* xdup(const char* s) {
  if (!s) return NULL;
  size_t n = strlen(s) + 1;
  char* p = (char*)malloc(n);
  if (p) memcpy(p, s, n);
  return p;
}

static int dirname_inplace(char* path) {
  if (!path || !path[0]) return 0;
  size_t n = strlen(path);
  while (n > 1 && (path[n - 1] == '/' || path[n - 1] == '\\')) {
    path[--n] = '\0';
  }
  char* slash = strrchr(path, '/');
#ifdef _WIN32
  char* bslash = strrchr(path, '\\');
  if (bslash && (!slash || bslash > slash)) slash = bslash;
#endif
  if (!slash) return 0;
  if (slash == path) {
    slash[1] = '\0';
    return 1;
  }
  *slash = '\0';
  return 1;
}

static void join_path(char* out, size_t cap, const char* dir, const char* rel) {
#if defined(_WIN32)
  snprintf(out, cap, "%s\\%s", dir, rel);
#else
  snprintf(out, cap, "%s/%s", dir, rel);
#endif
}

#if defined(_WIN32)
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
static int utf8_from_wide(const wchar_t* w, char* out, size_t cap) {
  if (!w || !out || cap == 0) return 0;
  int n = WideCharToMultiByte(CP_UTF8, 0, w, -1, out, (int)cap, NULL, NULL);
  return n > 0;
}
static int wide_from_utf8(const char* u, wchar_t* out, int cap) {
  if (!u || !out || cap <= 0) return 0;
  int n = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, u, -1, out, cap);
  return n > 0;
}
static int file_exists(const char* p) {
  wchar_t w[KOTV_PATH_MAX];
  if (!p || !p[0]) return 0;
  if (wide_from_utf8(p, w, KOTV_PATH_MAX)) {
    DWORD attr = GetFileAttributesW(w);
    if (attr != INVALID_FILE_ATTRIBUTES && !(attr & FILE_ATTRIBUTE_DIRECTORY)) return 1;
  }
  /* 兼容误把 ANSI 路径当 UTF-8 传入。 */
  if (MultiByteToWideChar(CP_ACP, 0, p, -1, w, KOTV_PATH_MAX) > 0) {
    DWORD attr = GetFileAttributesW(w);
    return attr != INVALID_FILE_ATTRIBUTES && !(attr & FILE_ATTRIBUTE_DIRECTORY);
  }
  return 0;
}
static int exe_dir(char* out, size_t cap) {
  wchar_t w[KOTV_PATH_MAX];
  DWORD n = GetModuleFileNameW(NULL, w, KOTV_PATH_MAX);
  if (!n || n >= KOTV_PATH_MAX) return 0;
  if (!utf8_from_wide(w, out, cap)) return 0;
  return dirname_inplace(out);
}
static int cwd_dir(char* out, size_t cap) {
  wchar_t w[KOTV_PATH_MAX];
  DWORD n = GetCurrentDirectoryW(KOTV_PATH_MAX, w);
  if (!n || n >= KOTV_PATH_MAX) return 0;
  return utf8_from_wide(w, out, cap);
}
static const char* kLeaves[] = {
    "mpv-2.dll",
    "libmpv-2.dll",
    "flutter\\assets\\mpv-libs\\windows\\mpv-2.dll",
    "assets\\mpv-libs\\windows\\mpv-2.dll",
};
static const char* kSystem[] = {NULL};
#else
#include <limits.h>
#include <unistd.h>
static int file_exists(const char* p) { return p && p[0] && access(p, F_OK) == 0; }
static int cwd_dir(char* out, size_t cap) { return getcwd(out, cap) != NULL; }
#if defined(__APPLE__)
#include <TargetConditionals.h>
#include <mach-o/dyld.h>
static int exe_dir(char* out, size_t cap) {
  uint32_t size = (uint32_t)cap;
  if (_NSGetExecutablePath(out, &size) != 0) return 0;
  char real[KOTV_PATH_MAX];
  if (realpath(out, real)) {
    snprintf(out, cap, "%s", real);
  }
  return dirname_inplace(out);
}
#if TARGET_OS_IPHONE
static const char* kLeaves[] = {
    "Frameworks/libmpv.dylib",
    "../Frameworks/libmpv.dylib",
    "libmpv.dylib",
    "flutter/assets/mpv-libs/ios/libmpv.dylib",
    "assets/mpv-libs/ios/libmpv.dylib",
};
static const char* kSystem[] = {NULL};
#else
static const char* kLeaves[] = {
    "../Frameworks/libmpv.dylib",
    "libmpv.dylib",
    "flutter/assets/mpv-libs/macos/libmpv.dylib",
    "assets/mpv-libs/macos/libmpv.dylib",
};
static const char* kSystem[] = {
    "/opt/homebrew/lib/libmpv.dylib",
    "/usr/local/lib/libmpv.dylib",
    "/opt/homebrew/opt/mpv/lib/libmpv.dylib",
    "/usr/local/opt/mpv/lib/libmpv.dylib",
    NULL,
};
#endif
#else
static int exe_dir(char* out, size_t cap) {
  ssize_t n = readlink("/proc/self/exe", out, cap - 1);
  if (n <= 0) return 0;
  out[n] = '\0';
  return dirname_inplace(out);
}
static const char* kLeaves[] = {
    "lib/libmpv.so.2",
    "lib/libmpv.so",
    "libmpv.so.2",
    "flutter/assets/mpv-libs/linux/libmpv.so.2",
    "assets/mpv-libs/linux/libmpv.so.2",
};
static const char* kSystem[] = {
    "/usr/lib/x86_64-linux-gnu/libmpv.so.2",
    "/usr/lib/aarch64-linux-gnu/libmpv.so.2",
    "/usr/lib64/libmpv.so.2",
    "/usr/lib/libmpv.so.2",
    NULL,
};
#endif
#endif

static char* probe_file(const char* path) {
  if (file_exists(path)) return xdup(path);
  return NULL;
}

static char* probe_join(const char* dir, const char* rel) {
  if (!dir || !dir[0] || !rel) return NULL;
  char buf[KOTV_PATH_MAX];
  join_path(buf, sizeof(buf), dir, rel);
  return probe_file(buf);
}

static char* walk_dir(const char* start) {
  if (!start || !start[0]) return NULL;
  char dir[KOTV_PATH_MAX];
  snprintf(dir, sizeof(dir), "%s", start);
  for (int up = 0; up <= 12; ++up) {
    for (size_t i = 0; i < sizeof(kLeaves) / sizeof(kLeaves[0]); ++i) {
      char* hit = probe_join(dir, kLeaves[i]);
      if (hit) return hit;
    }
    if (!dirname_inplace(dir)) break;
  }
  return NULL;
}

char* kotv_find_libmpv_path(void) {
  char base[KOTV_PATH_MAX];
  if (exe_dir(base, sizeof(base))) {
    char* hit = walk_dir(base);
    if (hit) return hit;
  }
  if (cwd_dir(base, sizeof(base))) {
    char* hit = walk_dir(base);
    if (hit) return hit;
  }

  for (size_t i = 0; kSystem[i]; ++i) {
    char* hit = probe_file(kSystem[i]);
    if (hit) return hit;
  }
  return NULL;
}
