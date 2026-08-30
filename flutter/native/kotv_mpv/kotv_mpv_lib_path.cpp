#include "kotv_mpv_lib_path.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#if defined(_WIN32)
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
static char* join_path(const char* dir, const char* leaf) {
  if (!dir || !leaf) return NULL;
  size_t n = strlen(dir) + strlen(leaf) + 2;
  char* out = (char*)malloc(n);
  if (!out) return NULL;
  snprintf(out, n, "%s\\%s", dir, leaf);
  return out;
}
static int file_exists(const char* p) {
  if (!p) return 0;
  DWORD attr = GetFileAttributesA(p);
  return attr != INVALID_FILE_ATTRIBUTES && !(attr & FILE_ATTRIBUTE_DIRECTORY);
}
char* kotv_find_libmpv_path(void) {
  char exe[MAX_PATH];
  if (!GetModuleFileNameA(NULL, exe, MAX_PATH)) return NULL;
  char* slash = strrchr(exe, '\\');
  if (!slash) return NULL;
  *slash = '\0';
  const char* rels[] = {"libmpv\\mpv-2.dll", "libmpv\\libmpv-2.dll", "mpv-2.dll", "libmpv-2.dll"};
  for (size_t i = 0; i < sizeof(rels) / sizeof(rels[0]); ++i) {
    char* p = join_path(exe, rels[i]);
    if (p && file_exists(p)) return p;
    free(p);
  }
  return NULL;
}
#elif defined(__APPLE__)
#include <dlfcn.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <stdio.h>
#include <unistd.h>
static int file_exists(const char* p) {
  return p && access(p, F_OK) == 0;
}
char* kotv_find_libmpv_path(void) {
  const char* cands[] = {
      "/opt/homebrew/lib/libmpv.dylib",
      "/usr/local/lib/libmpv.dylib",
      "/opt/homebrew/opt/mpv/lib/libmpv.dylib",
  };
  for (size_t i = 0; i < sizeof(cands) / sizeof(cands[0]); ++i) {
    if (file_exists(cands[i])) return strdup(cands[i]);
  }
  char exe[PATH_MAX];
  uint32_t size = sizeof(exe);
  if (_NSGetExecutablePath(exe, &size) == 0) {
    char* slash = strrchr(exe, '/');
    if (slash) {
      *slash = '\0';
      char buf[PATH_MAX];
      snprintf(buf, sizeof(buf), "%s/../Frameworks/libmpv.dylib", exe);
      if (file_exists(buf)) return strdup(buf);
      snprintf(buf, sizeof(buf), "%s/libmpv/libmpv.dylib", exe);
      if (file_exists(buf)) return strdup(buf);
    }
  }
  return NULL;
}
#else
#include <limits.h>
#include <stdio.h>
#include <unistd.h>
static int file_exists(const char* p) {
  return p && access(p, F_OK) == 0;
}
char* kotv_find_libmpv_path(void) {
  const char* cands[] = {
      "/usr/lib/x86_64-linux-gnu/libmpv.so.2",
      "/usr/lib/aarch64-linux-gnu/libmpv.so.2",
      "/usr/lib64/libmpv.so.2",
      "/usr/lib/libmpv.so.2",
  };
  for (size_t i = 0; i < sizeof(cands) / sizeof(cands[0]); ++i) {
    if (file_exists(cands[i])) return strdup(cands[i]);
  }
  char exe[PATH_MAX];
  ssize_t n = readlink("/proc/self/exe", exe, sizeof(exe) - 1);
  if (n > 0) {
    exe[n] = '\0';
    char* slash = strrchr(exe, '/');
    if (slash) {
      *slash = '\0';
      char buf[PATH_MAX];
      snprintf(buf, sizeof(buf), "%s/lib/libmpv.so.2", exe);
      if (file_exists(buf)) return strdup(buf);
      snprintf(buf, sizeof(buf), "%s/libmpv/libmpv.so.2", exe);
      if (file_exists(buf)) return strdup(buf);
    }
  }
  return NULL;
}
#endif
