#include "kotv_mpv_win_surface.h"

#if defined(_WIN32)

namespace {

const wchar_t kClassName[] = L"KotvMpvVideoHost";
bool g_class_registered = false;

void EnsureVideoHostClass() {
  if (g_class_registered) return;
  WNDCLASSEXW wc{};
  wc.cbSize = sizeof(wc);
  wc.lpfnWndProc = DefWindowProcW;
  wc.hInstance = GetModuleHandleW(nullptr);
  wc.lpszClassName = kClassName;
  wc.hbrBackground = reinterpret_cast<HBRUSH>(GetStockObject(BLACK_BRUSH));
  RegisterClassExW(&wc);
  g_class_registered = true;
}

}  // namespace

bool KotvMpvWinSurface::Ensure(HWND parent) {
  if (!parent) return false;
  if (parent_ != parent && hwnd_) {
    Destroy();
  }
  parent_ = parent;
  if (hwnd_) return true;
  EnsureVideoHostClass();
  hwnd_ = CreateWindowExW(
      WS_EX_NOPARENTNOTIFY, kClassName, L"",
      WS_CHILD | WS_VISIBLE | WS_CLIPSIBLINGS | WS_CLIPCHILDREN, 0, 0, 1, 1, parent_,
      nullptr, GetModuleHandleW(nullptr), nullptr);
  if (!hwnd_) return false;
  ShowWindow(hwnd_, SW_SHOW);
  return true;
}

void KotvMpvWinSurface::SetBounds(int x, int y, int w, int h) {
  if (!hwnd_) return;
  if (w < 1) w = 1;
  if (h < 1) h = 1;
  SetWindowPos(hwnd_, HWND_BOTTOM, x, y, w, h, SWP_NOACTIVATE | SWP_SHOWWINDOW);
}

void KotvMpvWinSurface::Destroy() {
  if (hwnd_) {
    DestroyWindow(hwnd_);
    hwnd_ = nullptr;
  }
  parent_ = nullptr;
}

#else

void KotvMpvWinSurface::Destroy() {}

#endif
