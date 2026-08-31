#ifndef KOTV_MPV_WIN_SURFACE_H
#define KOTV_MPV_WIN_SURFACE_H

#if defined(_WIN32)
#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>
#endif

#ifdef __cplusplus

class KotvMpvWinSurface {
 public:
  KotvMpvWinSurface() = default;
  ~KotvMpvWinSurface() { Destroy(); }

  KotvMpvWinSurface(const KotvMpvWinSurface&) = delete;
  KotvMpvWinSurface& operator=(const KotvMpvWinSurface&) = delete;

#if defined(_WIN32)
  bool Ensure(HWND parent);
  void SetBounds(int x, int y, int w, int h);
  HWND Hwnd() const { return hwnd_; }
  HWND Parent() const { return parent_; }
#endif
  void Destroy();

 private:
#if defined(_WIN32)
  HWND parent_ = nullptr;
  HWND hwnd_ = nullptr;
#endif
};

#endif

#endif
