#include "win7_chrome_shell.h"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <utility>

#include <windowsx.h>
#include <commctrl.h>
#pragma comment(lib, "comctl32.lib")

#include <gdiplus.h>

using kotv_chrome::Argb;
using kotv_chrome::Canvas;

namespace {

constexpr wchar_t kPanelClass[] = L"KotvWinChromePanel";
constexpr wchar_t kDanmakuClass[] = L"KotvWinChromeDanmaku";
constexpr wchar_t kGestureClass[] = L"KotvWinChromeGesture";
constexpr wchar_t kMsgClass[] = L"KotvWinChromeMsg";
constexpr UINT_PTR kSubclassHost = 0x4B4F5456;
constexpr UINT_PTR kSubclassRoot = 0x4B4F5457;
constexpr UINT kMsgRender = WM_APP + 0x4B1;
constexpr UINT_PTR kTimerVolume = 1;
constexpr UINT_PTR kTimerMini = 2;
constexpr UINT_PTR kTimerLongPress = 3;
constexpr UINT_PTR kTimerGestureHold = 4;
constexpr UINT_PTR kTimerClock = 5;
constexpr UINT_PTR kTimerDanmaku = 6;
constexpr UINT_PTR kTimerSpin = 7;
constexpr UINT_PTR kTimerMarquee = 8;
constexpr DWORD kLongPressMs = 500;     // kLongPressTimeout
constexpr DWORD kVolumeCollapseMs = 450;
constexpr DWORD kMiniHideMs = 2000;
constexpr double kTouchSlop = 18.0;     // kTouchSlop（逻辑像素）

using ChromeMap = Win7ChromeShell::ChromeMap;
using ChromeValue = Win7ChromeShell::ChromeValue;
using LineItem = Win7ChromeShell::LineItem;

ChromeValue Str(const char* s) { return ChromeValue(std::string(s)); }
ChromeValue Str(const std::string& s) { return ChromeValue(s); }
ChromeValue Int(int64_t v) { return ChromeValue(v); }

std::wstring Utf8ToWide(const std::string& utf8) {
  if (utf8.empty()) return {};
  const int n = MultiByteToWideChar(CP_UTF8, 0, utf8.c_str(), static_cast<int>(utf8.size()), nullptr, 0);
  if (n <= 0) return {};
  std::wstring out(static_cast<size_t>(n), L'\0');
  MultiByteToWideChar(CP_UTF8, 0, utf8.c_str(), static_cast<int>(utf8.size()), &out[0], n);
  return out;
}

std::string GetString(const ChromeMap& m, const char* key) {
  const auto it = m.find(key);
  if (it == m.end() || !std::holds_alternative<std::string>(it->second)) return {};
  return std::get<std::string>(it->second);
}

bool GetBool(const ChromeMap& m, const char* key, bool def) {
  const auto it = m.find(key);
  if (it == m.end() || !std::holds_alternative<bool>(it->second)) return def;
  return std::get<bool>(it->second);
}

double GetDouble(const ChromeMap& m, const char* key, double def) {
  const auto it = m.find(key);
  if (it == m.end()) return def;
  if (std::holds_alternative<double>(it->second)) return std::get<double>(it->second);
  if (std::holds_alternative<int64_t>(it->second)) return static_cast<double>(std::get<int64_t>(it->second));
  return def;
}

int GetInt(const ChromeMap& m, const char* key, int def) {
  return static_cast<int>(std::lround(GetDouble(m, key, def)));
}

bool HasKey(const ChromeMap& m, const char* key) { return m.find(key) != m.end(); }

std::vector<std::string> SplitLines(const std::string& s) {
  std::vector<std::string> out;
  if (s.empty()) return out;
  size_t start = 0;
  while (true) {
    const size_t p = s.find('\n', start);
    if (p == std::string::npos) {
      out.push_back(s.substr(start));
      break;
    }
    out.push_back(s.substr(start, p - start));
    start = p + 1;
  }
  return out;
}

std::wstring DecodeField(const std::string& s) {
  std::wstring w = Utf8ToWide(s);
  for (auto& c : w) {
    if (c == 0x1F) c = L'\n';
  }
  return w;
}

std::vector<std::wstring> GetWideList(const ChromeMap& m, const char* key) {
  std::vector<std::wstring> out;
  for (const auto& l : SplitLines(GetString(m, key))) out.push_back(DecodeField(l));
  return out;
}

std::vector<LineItem> ParseLineItems(const ChromeMap& m, const char* key) {
  std::vector<LineItem> out;
  for (const auto& line : SplitLines(GetString(m, key))) {
    if (line.empty()) continue;
    std::vector<std::string> cols;
    size_t cs = 0;
    while (true) {
      const size_t c = line.find('|', cs);
      if (c == std::string::npos) {
        cols.push_back(line.substr(cs));
        break;
      }
      cols.push_back(line.substr(cs, c - cs));
      cs = c + 1;
    }
    while (cols.size() < 15) cols.emplace_back();
    LineItem it;
    it.id = cols[0];
    it.label = DecodeField(cols[1]);
    it.trailing = DecodeField(cols[2]);
    it.toggle = cols[3] == "1";
    it.on = cols[4] == "1";
    it.chevron = cols[5] == "1";
    it.slider = cols[6] == "1";
    it.slider_min = cols[7].empty() ? 0 : std::strtod(cols[7].c_str(), nullptr);
    it.slider_max = cols[8].empty() ? 100 : std::strtod(cols[8].c_str(), nullptr);
    it.slider_value = cols[9].empty() ? 0 : std::strtod(cols[9].c_str(), nullptr);
    it.icon = cols[10];
    it.kind = cols[11];
    it.selected = cols[12] == "1";
    it.sub = DecodeField(cols[13]);
    it.divisions = cols[14].empty() ? 0 : std::atoi(cols[14].c_str());
    if (it.kind.empty()) {
      if (it.slider) it.kind = "slider";
      else if (it.toggle) it.kind = "toggle";
    }
    out.push_back(std::move(it));
  }
  return out;
}

Argb ParseArgb(const ChromeMap& m, const char* key, Argb def) {
  if (!HasKey(m, key)) return def;
  return static_cast<Argb>(static_cast<int64_t>(GetDouble(m, key, def)) & 0xFFFFFFFF);
}

const char* VkToLogicalName(WPARAM vk) {
  switch (vk) {
    case VK_ESCAPE: return "Escape";
    case VK_RETURN: return "Enter";
    case VK_SPACE: return "Space";
    case VK_LEFT: return "ArrowLeft";
    case VK_RIGHT: return "ArrowRight";
    case VK_UP: return "ArrowUp";
    case VK_DOWN: return "ArrowDown";
    case VK_PRIOR: return "PageUp";
    case VK_NEXT: return "PageDown";
    case VK_APPS: return "ContextMenu";
    case VK_BACK: return "GoBack";
    case VK_MEDIA_PLAY_PAUSE: return "MediaPlayPause";
    case VK_MEDIA_NEXT_TRACK: return "MediaTrackNext";
    case VK_MEDIA_PREV_TRACK: return "MediaTrackPrevious";
    case VK_VOLUME_UP: return "VolumeUp";
    case VK_VOLUME_DOWN: return "VolumeDown";
    case VK_VOLUME_MUTE: return "VolumeMute";
    case 'E': return "KeyE";
    case 'M': return "KeyM";
    case 'S': return "KeyS";
    case '0': return "Digit0";
    case '1': return "Digit1";
    case '2': return "Digit2";
    case '3': return "Digit3";
    case '4': return "Digit4";
    case '5': return "Digit5";
    case '6': return "Digit6";
    case '7': return "Digit7";
    case '8': return "Digit8";
    case '9': return "Digit9";
    case VK_NUMPAD0: return "Digit0";
    case VK_NUMPAD1: return "Digit1";
    case VK_NUMPAD2: return "Digit2";
    case VK_NUMPAD3: return "Digit3";
    case VK_NUMPAD4: return "Digit4";
    case VK_NUMPAD5: return "Digit5";
    case VK_NUMPAD6: return "Digit6";
    case VK_NUMPAD7: return "Digit7";
    case VK_NUMPAD8: return "Digit8";
    case VK_NUMPAD9: return "Digit9";
    default: return nullptr;
  }
}

const char* AppCommandToLogicalName(int cmd) {
  switch (cmd) {
    case APPCOMMAND_MEDIA_PLAY_PAUSE: return "MediaPlayPause";
    case APPCOMMAND_MEDIA_PREVIOUSTRACK: return "MediaTrackPrevious";
    case APPCOMMAND_MEDIA_NEXTTRACK: return "MediaTrackNext";
    case APPCOMMAND_MEDIA_REWIND: return "MediaRewind";
    case APPCOMMAND_MEDIA_FAST_FORWARD: return "MediaFastForward";
    case APPCOMMAND_VOLUME_UP: return "VolumeUp";
    case APPCOMMAND_VOLUME_DOWN: return "VolumeDown";
    case APPCOMMAND_VOLUME_MUTE: return "VolumeMute";
    default: return nullptr;
  }
}

bool SameRect(const RECT& a, const RECT& b) {
  return a.left == b.left && a.top == b.top && a.right == b.right && a.bottom == b.bottom;
}

double Snap(double v, const LineItem& it) {
  const double lo = it.slider_min;
  const double hi = it.slider_max;
  v = std::clamp(v, std::min(lo, hi), std::max(lo, hi));
  if (it.divisions > 0 && hi > lo) {
    const double step = (hi - lo) / it.divisions;
    v = lo + std::round((v - lo) / step) * step;
  }
  return v;
}

std::wstring FormatValue(const std::wstring& fmt, double v) {
  if (fmt.empty()) {
    wchar_t buf[32];
    swprintf_s(buf, L"%d", static_cast<int>(std::lround(v)));
    return buf;
  }
  wchar_t buf[64];
  swprintf_s(buf, fmt.c_str(), v);
  return buf;
}

bool IsTrackKind(const std::string& k) {
  return k == "subtitle" || k == "audio" || k == "video" || k == "disc";
}

}  // namespace

// ---------------------------------------------------------------------------
// 生命周期
// ---------------------------------------------------------------------------

Win7ChromeShell::Win7ChromeShell() {
  Gdiplus::GdiplusStartupInput input;
  Gdiplus::GdiplusStartup(&gdiplus_token_, &input, nullptr);
}

Win7ChromeShell::~Win7ChromeShell() {
  SubclassHost(false);
  DestroyAll();
  if (gdiplus_token_) Gdiplus::GdiplusShutdown(gdiplus_token_);
}

void Win7ChromeShell::Attach(HWND host) {
  if (host == host_hwnd_) return;
  SubclassHost(false);
  DestroyAll();
  host_hwnd_ = host;
  if (enabled_) {
    EnsureWindows();
    SubclassHost(true);
    Layout();
  }
}

void Win7ChromeShell::SetEnabled(bool enabled) {
  if (enabled == enabled_) {
    if (enabled) Layout();
    return;
  }
  enabled_ = enabled;
  if (enabled) {
    EnsureWindows();
    SubclassHost(true);
    Layout();
    return;
  }
  CloseSheet(false);
  ClosePopup();
  HideAllPanels();
  if (gesture_hwnd_) ShowWindow(gesture_hwnd_, SW_HIDE);
  if (danmaku_hwnd_) ShowWindow(danmaku_hwnd_, SW_HIDE);
  if (msg_hwnd_) {
    for (UINT_PTR t : {kTimerVolume, kTimerMini, kTimerLongPress, kTimerGestureHold, kTimerClock, kTimerDanmaku, kTimerSpin, kTimerMarquee})
      KillTimer(msg_hwnd_, t);
  }
  danmaku_timer_ = false;
  marquee_panels_ = 0;
  marquee_running_ = false;
  if (pointer_hold_) EmitPointerHold(false);
  for (bool& h : panel_hover_) h = false;
  volume_expanded_ = false;
  hud_kind_ = HudKind::None;
  mode_.clear();
  SubclassHost(false);
}

HWND Win7ChromeShell::RootHwnd() const {
  return host_hwnd_ ? GetAncestor(host_hwnd_, GA_ROOT) : nullptr;
}

void Win7ChromeShell::EnsureWindows() {
  if (!host_hwnd_) return;
  HINSTANCE inst = GetModuleHandleW(nullptr);
  static bool registered = false;
  if (!registered) {
    registered = true;
    WNDCLASSW wc{};
    wc.hInstance = inst;
    wc.hCursor = LoadCursor(nullptr, IDC_ARROW);
    wc.lpfnWndProc = PanelWndProc;
    wc.lpszClassName = kPanelClass;
    RegisterClassW(&wc);
    wc.lpfnWndProc = GestureWndProc;
    wc.lpszClassName = kGestureClass;
    RegisterClassW(&wc);
    wc.lpfnWndProc = MsgWndProc;
    wc.lpszClassName = kMsgClass;
    RegisterClassW(&wc);
    wc.lpfnWndProc = DanmakuWndProc;
    wc.lpszClassName = kDanmakuClass;
    RegisterClassW(&wc);
  }
  if (!msg_hwnd_) {
    msg_hwnd_ = CreateWindowExW(0, kMsgClass, L"", 0, 0, 0, 0, 0, HWND_MESSAGE, nullptr, inst, this);
  }
  if (!gesture_hwnd_) {
    gesture_hwnd_ = CreateWindowExW(0, kGestureClass, L"", WS_CHILD | WS_CLIPSIBLINGS, 0, 0, 1, 1, host_hwnd_,
                                    nullptr, inst, this);
  }
  HWND root = RootHwnd();
  if (!danmaku_hwnd_) {
    danmaku_hwnd_ = CreateWindowExW(WS_EX_LAYERED | WS_EX_TRANSPARENT | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE,
                                    kDanmakuClass, L"", WS_POPUP, 0, 0, 1, 1, root, nullptr, inst, this);
  }
  for (int i = 0; i < kPanelCount; ++i) {
    Panel& p = panels_[i];
    if (p.hwnd) continue;
    p.click_through = i == kDebug || i == kHud || i == kZap || i == kBuffer || i == kPeek;
    const DWORD ex = WS_EX_LAYERED | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE | (p.click_through ? WS_EX_TRANSPARENT : 0);
    p.hwnd = CreateWindowExW(ex, kPanelClass, L"", WS_POPUP, 0, 0, 1, 1, root, nullptr, inst, this);
    p.canvas = std::make_unique<Canvas>();
    p.shown = false;
    p.dirty = true;
  }
}

void Win7ChromeShell::DestroyAll() {
  for (auto& p : panels_) {
    if (p.hwnd) DestroyWindow(p.hwnd);
    p.hwnd = nullptr;
    p.shown = false;
    p.hits.clear();
    p.canvas.reset();
  }
  if (danmaku_hwnd_) DestroyWindow(danmaku_hwnd_);
  danmaku_hwnd_ = nullptr;
  danmaku_canvas_.reset();
  if (gesture_hwnd_) DestroyWindow(gesture_hwnd_);
  gesture_hwnd_ = nullptr;
  if (msg_hwnd_) DestroyWindow(msg_hwnd_);
  msg_hwnd_ = nullptr;
  render_posted_ = false;
  danmaku_timer_ = false;
}

void Win7ChromeShell::SubclassHost(bool enable) {
  if (enable) {
    if (host_hwnd_ && !host_subclassed_) {
      SetWindowSubclass(host_hwnd_, HostSubclassProc, kSubclassHost, reinterpret_cast<DWORD_PTR>(this));
      host_subclassed_ = true;
    }
    HWND root = RootHwnd();
    if (root && root != host_hwnd_ && subclassed_root_ != root) {
      if (subclassed_root_) RemoveWindowSubclass(subclassed_root_, RootSubclassProc, kSubclassRoot);
      SetWindowSubclass(root, RootSubclassProc, kSubclassRoot, reinterpret_cast<DWORD_PTR>(this));
      subclassed_root_ = root;
    }
    return;
  }
  if (host_hwnd_ && host_subclassed_) {
    RemoveWindowSubclass(host_hwnd_, HostSubclassProc, kSubclassHost);
  }
  host_subclassed_ = false;
  if (subclassed_root_) {
    RemoveWindowSubclass(subclassed_root_, RootSubclassProc, kSubclassRoot);
    subclassed_root_ = nullptr;
  }
}

// ---------------------------------------------------------------------------
// 尺寸
// ---------------------------------------------------------------------------

void Win7ChromeShell::UpdateMetrics() {
  if (dpr_override_ > 0) {
    dpr_ = dpr_override_;
  } else if (host_hwnd_) {
    HDC dc = GetDC(host_hwnd_);
    dpr_ = std::max(1.0, GetDeviceCaps(dc, LOGPIXELSX) / 96.0);
    ReleaseDC(host_hwnd_, dc);
  }
  const RECT hc = HostClient();
  const double w = (hc.right - hc.left) / dpr_;
  const double h = (hc.bottom - hc.top) / dpr_;
  land_ = w >= h && h < 520;
}

int Win7ChromeShell::P(double v) const { return static_cast<int>(std::lround(v * dpr_)); }
int Win7ChromeShell::G(double v) const { return static_cast<int>(std::lround(v * grow_ * dpr_)); }
int Win7ChromeShell::L(double v) const { return static_cast<int>(std::lround(v * layout_of_ * dpr_)); }
float Win7ChromeShell::F(double v) const { return static_cast<float>(v * text_scale_ * dpr_); }
float Win7ChromeShell::FL(double v) const { return static_cast<float>(v * layout_of_ * dpr_); }

RECT Win7ChromeShell::HostClient() const {
  RECT rc{};
  if (host_hwnd_) GetClientRect(host_hwnd_, &rc);
  return rc;
}

bool Win7ChromeShell::HostRectFromLogical(double l, double t, double w, double h, RECT* out) const {
  if (w < 1 || h < 1) return false;
  out->left = static_cast<LONG>(std::lround(l * dpr_));
  out->top = static_cast<LONG>(std::lround(t * dpr_));
  out->right = static_cast<LONG>(std::lround((l + w) * dpr_));
  out->bottom = static_cast<LONG>(std::lround((t + h) * dpr_));
  return true;
}

bool Win7ChromeShell::InlineClip(RECT* out) const {
  if (mode_ != "vod_inline" || !clip_valid_) return false;
  return HostRectFromLogical(clip_l_, clip_t_, clip_w_, clip_h_, out);
}

RECT Win7ChromeShell::VideoArea() const {
  RECT rc = HostClient();
  // 全屏点播铺满 Flutter 视图；不能沿用内嵌时的 surface。
  if (IsMini() || mode_ == "vod") return rc;
  RECT s{};
  if (surface_valid_ && HostRectFromLogical(surface_l_, surface_t_, surface_w_, surface_h_, &s)) {
    IntersectRect(&s, &s, &rc);
    if (s.right > s.left && s.bottom > s.top) return s;
  }
  return rc;
}

double Win7ChromeShell::TotalSec() const {
  return duration_sec_ > 0 ? duration_sec_ : 0;
}

// ---------------------------------------------------------------------------
// 面板显示 / 渲染
// ---------------------------------------------------------------------------

void Win7ChromeShell::ShowPanel(PanelId id, bool show, const RECT& rc) {
  Panel& p = panels_[id];
  if (!p.hwnd) return;
  if (!show || rc.right <= rc.left || rc.bottom <= rc.top) {
    if (p.shown) {
      ShowWindow(p.hwnd, SW_HIDE);
      p.shown = false;
      p.hits.clear();
      if (panel_hover_[id]) {
        panel_hover_[id] = false;
        bool any = false;
        for (bool h : panel_hover_) any = any || h;
        if (!any && pointer_hold_) EmitPointerHold(false);
      }
    }
    return;
  }
  const bool sized = !SameRect(p.rc, rc);
  p.rc = rc;
  if (sized) p.dirty = true;
  if (p.dirty || !p.shown) {
    Render(id);
  } else {
    POINT pt{rc.left, rc.top};
    ClientToScreen(host_hwnd_, &pt);
    SetWindowPos(p.hwnd, nullptr, pt.x, pt.y, 0, 0, SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE);
  }
  if (!p.shown) {
    ShowWindow(p.hwnd, SW_SHOWNOACTIVATE);
    p.shown = true;
    if (id == kSheet || id == kPopup) {
      SetWindowPos(p.hwnd, HWND_TOP, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
    }
  }
}

void Win7ChromeShell::HideAllPanels() {
  for (int i = 0; i < kPanelCount; ++i) ShowPanel(static_cast<PanelId>(i), false, RECT{});
}

void Win7ChromeShell::Render(PanelId id) {
  Panel& p = panels_[id];
  if (!p.hwnd || !p.canvas) return;
  const int w = p.rc.right - p.rc.left;
  const int h = p.rc.bottom - p.rc.top;
  if (w <= 0 || h <= 0) return;
  Canvas& cv = *p.canvas;
  if (!cv.Begin(w, h)) return;
  p.hits.clear();
  const uint32_t bit = 1u << id;
  marquee_panels_ &= ~bit;
  painting_ = id;
  Paint(id, cv, p.hits);
  painting_ = kPanelCount;
  cv.End();
  RECT clip{};
  if (id != kSheet && id != kPopup && InlineClip(&clip)) {
    OffsetRect(&clip, -p.rc.left, -p.rc.top);
    cv.ClearOutside(clip);
  }
  POINT pt{p.rc.left, p.rc.top};
  ClientToScreen(host_hwnd_, &pt);
  kotv_chrome::PresentLayered(p.hwnd, cv, pt.x, pt.y);
  p.dirty = false;
}

void Win7ChromeShell::MarkDirty(PanelId id) {
  panels_[id].dirty = true;
  ScheduleRender();
}

void Win7ChromeShell::ScheduleRender() {
  if (render_posted_ || !msg_hwnd_) return;
  render_posted_ = true;
  PostMessageW(msg_hwnd_, kMsgRender, 0, 0);
}

void Win7ChromeShell::RenderDirty() {
  render_posted_ = false;
  if (!enabled_) return;
  for (int i = 0; i < kPanelCount; ++i) {
    Panel& p = panels_[i];
    if (p.shown && p.dirty) Render(static_cast<PanelId>(i));
  }
  UpdateMarqueeTimer();
}

void Win7ChromeShell::UpdateMarqueeTimer() {
  for (int i = 0; i < kPanelCount; ++i) {
    if (!panels_[i].shown) marquee_panels_ &= ~(1u << i);
  }
  if (!msg_hwnd_ || (marquee_panels_ != 0) == marquee_running_) return;
  marquee_running_ = marquee_panels_ != 0;
  if (marquee_running_) SetTimer(msg_hwnd_, kTimerMarquee, 40, nullptr);
  else KillTimer(msg_hwnd_, kTimerMarquee);
}

void Win7ChromeShell::InvalidateChrome() {
  if (!enabled_) return;
  for (auto& p : panels_) p.dirty = true;
  ScheduleRender();
}

// ---------------------------------------------------------------------------
// 布局
// ---------------------------------------------------------------------------

void Win7ChromeShell::Layout() {
  if (!enabled_ || !host_hwnd_) return;
  EnsureWindows();
  UpdateMetrics();
  if (suspended_ || mode_.empty() || !IsWindowVisible(host_hwnd_)) {
    HideAllPanels();
    if (gesture_hwnd_) ShowWindow(gesture_hwnd_, SW_HIDE);
    if (danmaku_hwnd_) ShowWindow(danmaku_hwnd_, SW_HIDE);
    if (msg_hwnd_) KillTimer(msg_hwnd_, kTimerSpin);
    UpdateDanmakuTimer();
    return;
  }
  const RECT hc = HostClient();
  const RECT box = VideoArea();
  const int W = box.right - box.left;
  bool want[kPanelCount] = {};
  RECT rcs[kPanelCount] = {};
  auto put = [&](PanelId id, RECT r) {
    want[id] = true;
    rcs[id] = r;
  };
  auto center_rect = [&]() {
    const int d = G(land_ ? 56 : 72);
    const int cx = (box.left + box.right) / 2;
    const int cy = (box.top + box.bottom) / 2;
    return RECT{cx - d / 2, cy - d / 2, cx - d / 2 + d, cy - d / 2 + d};
  };

  if (mode_ == "vod_inline") {
    RECT a{};
    if (bottom_visible_ && anchor_valid_ && HostRectFromLogical(anchor_l_, anchor_t_, anchor_w_, anchor_h_, &a)) {
      const int h = InlineBarH(a.right - a.left);
      put(kBottom, RECT{a.left, a.top, a.right, a.top + h});
    }
    if (center_visible_) put(kCenter, center_rect());
  } else if (mode_ == "vod") {
    if (top_visible_ && !episodes_visible_) put(kTop, RECT{box.left, box.top, box.right, box.top + FullscreenTopH()});
    if (bottom_visible_ && !episodes_visible_) {
      put(kBottom, RECT{box.left, box.bottom - FullscreenBottomH(), box.right, box.bottom});
    }
    if (episodes_visible_) put(kEpisodes, RECT{box.right - P(280), box.top, box.right, box.bottom});
    if (center_visible_ && !episodes_visible_) put(kCenter, center_rect());
  } else if (mode_ == "live") {
    if (live_left_visible_) put(kLiveLeft, RECT{box.left, box.top, box.left + LiveLeftW(W), box.bottom});
    if (live_right_visible_) put(kLiveRight, RECT{box.right - LiveRightW(W), box.top, box.right, box.bottom});
    const bool side = live_left_visible_ || live_right_visible_;
    if (!side && catchup_bar_) put(kBottom, RECT{box.left, box.bottom - CatchupBarH(W), box.right, box.bottom});
    if (!side && channel_visible_ && !catchup_bar_) {
      put(kChannel, RECT{box.left + P(16), box.bottom - P(16) - ChannelBarH(), box.right - P(16), box.bottom - P(16)});
    }
    if (!side && !pill_label_.empty()) {
      const bool immersive = fullscreen_active_;
      const bool catchup_back = pill_label_ == L"返回直播";
      double pw = land_ ? (catchup_back ? 96.0 : 78.0) : (catchup_back ? 110.0 : 96.0);
      if (!immersive && !catchup_back) pw = land_ ? 78.0 : 96.0;
      const double ph = land_ ? 28.0 : 36.0;
      const int x = box.left + P(land_ ? 10 : 16);
      const int y = box.top + P(land_ ? 8 : 12);
      put(kPill, RECT{x, y, x + L(pw), y + L(ph)});
    }
    if (!side && center_visible_) put(kCenter, center_rect());
  } else if (IsMini()) {
    if (mini_bar_shown_) {
      const int w = hc.right - hc.left;
      const int h = mini_kind_ == "live" ? CatchupBarH(w) : InlineBarH(w);
      put(kBottom, RECT{hc.left, hc.bottom - h, hc.right, hc.bottom});
    }
  }

  static Canvas measure;
  if (debug_hud_on_ && mode_ == "vod" && !debug_text_.empty()) {
    int tw = 0;
    int lines = 0;
    size_t s = 0;
    while (s <= debug_text_.size()) {
      size_t e = debug_text_.find(L'\n', s);
      if (e == std::wstring::npos) e = debug_text_.size();
      tw = std::max(tw, measure.Measure(debug_text_.substr(s, e - s), F(11), 400));
      ++lines;
      s = e + 1;
    }
    const int lh = static_cast<int>(F(11) * 1.35f);
    const int x = box.left + P(12);
    const int y = box.top + P(8);
    put(kDebug, RECT{x, y, x + tw + P(16), y + lines * lh + P(12)});
  }
  if (!zap_digits_.empty()) {
    const int tw = measure.Measure(zap_digits_, F(56), 800) + P(2) * static_cast<int>(zap_digits_.size()) + P(16);
    const int th = measure.LineHeight(F(56), 800) + P(16);
    put(kZap, RECT{box.right - P(36) - tw + P(8), box.top + P(48) - P(8), box.right - P(36) + P(8), box.top + P(48) - P(8) + th});
  }
  if (!live_error_.empty() && mode_ == "live") {
    const int tw = measure.Measure(live_error_, F(14), 400) + P(4);
    const int th = measure.LineHeight(F(14), 400);
    const int cx = (box.left + box.right) / 2;
    const int cy = (box.top + box.bottom) / 2;
    if (!want[kZap]) {
      put(kZap, RECT{cx - tw / 2, cy - th / 2, cx - tw / 2 + tw, cy - th / 2 + th});
    }
  }
  if (!buffer_text_.empty()) {
    const int d = G(28);
    const int tw = measure.Measure(buffer_text_, F(15), 600);
    const int th = static_cast<int>(std::ceil(F(15) * 1.2f));
    const int w = std::max(d, tw) + G(18) * 2;
    const int h = G(14) + d + G(10) + th + G(14);
    const int cx = (box.left + box.right) / 2;
    const int cy = (box.top + box.bottom) / 2;
    put(kBuffer, RECT{cx - w / 2, cy - h / 2, cx - w / 2 + w, cy - h / 2 + h});
  }
  if (mode_ == "vod") {
    const int dy = P(swipe_dy_);
    if (dy > P(8) && !swipe_prev_.empty()) {
      put(kPeek, RECT{box.left, box.top, box.right, std::min(box.bottom, box.top + dy)});
    } else if (dy < -P(8) && !swipe_next_.empty()) {
      put(kPeek, RECT{box.left, std::max(box.top, box.bottom + dy), box.right, box.bottom});
    }
  }
  if (sheet_kind_.size()) put(kSheet, hc);
  if (popup_open_) put(kPopup, hc);

  RECT clip{};
  if (InlineClip(&clip)) {
    for (int i = 0; i < kPanelCount; ++i) {
      RECT vis{};
      if (want[i] && i != kSheet && i != kPopup && !IntersectRect(&vis, &rcs[i], &clip)) want[i] = false;
    }
  }
  for (int i = 0; i < kPanelCount; ++i) {
    if (i == kHud) continue;
    ShowPanel(static_cast<PanelId>(i), want[i], rcs[i]);
  }
  LayoutHud();
  LayoutGesture();
  LayoutDanmaku();
  if (msg_hwnd_) {
    if (mode_ == "vod" && panels_[kBottom].shown) SetTimer(msg_hwnd_, kTimerClock, 1000, nullptr);
    else KillTimer(msg_hwnd_, kTimerClock);
    if (panels_[kBuffer].shown) SetTimer(msg_hwnd_, kTimerSpin, 16, nullptr);
    else KillTimer(msg_hwnd_, kTimerSpin);
  }
}

void Win7ChromeShell::LayoutGesture() {
  if (!gesture_hwnd_) return;
  RECT r = VideoArea();
  if (mode_ == "vod_inline" && !surface_valid_) r = RECT{};
  RECT clip{};
  if (InlineClip(&clip) && !IntersectRect(&r, &r, &clip)) r = RECT{};
  if (r.right <= r.left || r.bottom <= r.top) {
    ShowWindow(gesture_hwnd_, SW_HIDE);
    return;
  }
  SetWindowPos(gesture_hwnd_, HWND_BOTTOM, r.left, r.top, r.right - r.left, r.bottom - r.top,
               SWP_NOACTIVATE | SWP_SHOWWINDOW);
}

void Win7ChromeShell::LayoutHud() {
  if (hud_kind_ == HudKind::None) {
    ShowPanel(kHud, false, RECT{});
    return;
  }
  static Canvas measure;
  const double u = hud_ui_ ? grow_ : 1.0;
  int w = 0;
  int h = 0;
  auto px = [&](double v) { return static_cast<int>(std::lround(v * u * dpr_)); };
  if (hud_kind_ == HudKind::Text) {
    const float fs = F(hud_size_);
    w = measure.Measure(hud_text_, fs, 700) + px(18) * 2;
    h = measure.LineHeight(fs, 700) + px(10) * 2;
  } else if (hud_kind_ == HudKind::Side) {
    const float fs = static_cast<float>(F(16) * u);
    w = px(22) + px(10) + measure.Measure(hud_text_, fs, 700) + px(20) * 2;
    h = std::max(px(22), measure.LineHeight(fs, 700)) + px(12) * 2;
  } else {
    const float fs = static_cast<float>(F(18) * u);
    w = px(28) + px(12) + measure.Measure(hud_text_, fs, 700) + px(22) * 2;
    h = std::max(px(28), measure.LineHeight(fs, 700)) + px(14) * 2;
  }
  const RECT box = VideoArea();
  const int cx = (box.left + box.right) / 2;
  const int cy = (box.top + box.bottom) / 2;
  RECT rc{cx - w / 2, cy - h / 2, cx - w / 2 + w, cy - h / 2 + h};
  panels_[kHud].dirty = true;
  ShowPanel(kHud, true, rc);
}

void Win7ChromeShell::SetHud(HudKind kind, const std::wstring& text, uint32_t icon, double size, bool ui) {
  const bool same = kind == hud_kind_ && text == hud_text_ && icon == hud_icon_ && size == hud_size_ && ui == hud_ui_;
  hud_kind_ = kind;
  hud_text_ = text;
  hud_icon_ = icon;
  hud_size_ = size;
  hud_ui_ = ui;
  if (!same && enabled_) LayoutHud();
}

void Win7ChromeShell::LayoutDanmaku() {
  if (!danmaku_hwnd_) return;
  const bool show = danmaku_enabled_ && !suspended_ && !IsMini() && !mode_.empty() &&
                    (mode_ == "vod" || mode_ == "vod_inline" || mode_ == "live");
  if (!show) {
    ShowWindow(danmaku_hwnd_, SW_HIDE);
    UpdateDanmakuTimer();
    return;
  }
  PaintDanmaku();
  if (!IsWindowVisible(danmaku_hwnd_)) {
    ShowWindow(danmaku_hwnd_, SW_SHOWNOACTIVATE);
    // 弹幕压在播控之下：放到 owner 组的最底层（仍在宿主之上）。
    for (auto& p : panels_) {
      if (p.shown) SetWindowPos(p.hwnd, HWND_TOP, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
    }
  }
  UpdateDanmakuTimer();
}

void Win7ChromeShell::UpdateDanmakuTimer() {
  if (!msg_hwnd_) return;
  const bool want = danmaku_hwnd_ && IsWindowVisible(danmaku_hwnd_) && danmaku_enabled_ && !danmaku_items_.empty();
  if (want == danmaku_timer_) return;
  danmaku_timer_ = want;
  if (want) {
    SetTimer(msg_hwnd_, kTimerDanmaku, 33, nullptr);
  } else {
    KillTimer(msg_hwnd_, kTimerDanmaku);
  }
}

void Win7ChromeShell::LayoutSheet() {
  if (!enabled_) return;
  if (sheet_kind_.empty()) {
    ShowPanel(kSheet, false, RECT{});
    return;
  }
  panels_[kSheet].dirty = true;
  ShowPanel(kSheet, true, HostClient());
}

// ---------------------------------------------------------------------------
// Dart → 壳
// ---------------------------------------------------------------------------

bool Win7ChromeShell::ApplyUpdate(const ChromeMap& a) {
  bool layout = false;
  auto set_bool = [&](bool& field, const char* key) {
    if (!HasKey(a, key)) return;
    const bool v = GetBool(a, key, field);
    if (v != field) layout = true;
    field = v;
  };
  auto set_wstr = [&](std::wstring& field, const char* key) {
    if (HasKey(a, key)) field = DecodeField(GetString(a, key));
  };

  if (HasKey(a, "mode")) {
    const std::string next = GetString(a, "mode");
    if (next != mode_) {
      layout = true;
      volume_expanded_ = false;
      mini_bar_shown_ = false;
      mini_hover_ = false;
      ClosePopup();
      if (!sheet_kind_.empty()) CloseSheet(false);
    }
    mode_ = next;
  }
  if (HasKey(a, "miniKind")) mini_kind_ = GetString(a, "miniKind");
  set_bool(suspended_, "suspended");
  if (HasKey(a, "dpr")) {
    const double v = GetDouble(a, "dpr", 0);
    if (std::abs(v - dpr_override_) > 1e-6) layout = true;
    dpr_override_ = v;
  }
  if (HasKey(a, "uiScale")) {
    const double s = std::max(0.55, GetDouble(a, "uiScale", 1.0));
    const double t = GetDouble(a, "textScale", s < 0.85 ? 1.0 : s);
    if (std::abs(s - scale_) > 1e-6 || std::abs(t - text_scale_) > 1e-6) layout = true;
    scale_ = s;
    grow_ = s > 1 ? s : 1;
    text_scale_ = t;
    layout_of_ = std::max(s, t);
  }
  pal_primary_ = ParseArgb(a, "palPrimary", pal_primary_);
  pal_fg_ = ParseArgb(a, "palFg", pal_fg_);
  pal_muted_ = ParseArgb(a, "palMuted", pal_muted_);
  pal_pill_bg_ = ParseArgb(a, "palPillBg", pal_pill_bg_);
  pal_pill_border_ = ParseArgb(a, "palPillBorder", pal_pill_border_);
  pal_dialog_bg_ = ParseArgb(a, "palDialogBg", pal_dialog_bg_);
  pal_selected_ = ParseArgb(a, "palSelected", pal_selected_);

  if (HasKey(a, "anchorWidth")) {
    const double l = GetDouble(a, "anchorLeft", 0), t = GetDouble(a, "anchorTop", 0);
    const double w = GetDouble(a, "anchorWidth", 0), h = GetDouble(a, "anchorHeight", 0);
    if (std::abs(l - anchor_l_) > 0.5 || std::abs(t - anchor_t_) > 0.5 || std::abs(w - anchor_w_) > 0.5 ||
        std::abs(h - anchor_h_) > 0.5) {
      layout = true;
    }
    anchor_l_ = l;
    anchor_t_ = t;
    anchor_w_ = w;
    anchor_h_ = h;
    anchor_valid_ = w >= 8 && h >= 8;
  }
  if (HasKey(a, "surfaceWidth")) {
    const double l = GetDouble(a, "surfaceLeft", 0), t = GetDouble(a, "surfaceTop", 0);
    const double w = GetDouble(a, "surfaceWidth", 0), h = GetDouble(a, "surfaceHeight", 0);
    if (std::abs(l - surface_l_) > 0.5 || std::abs(t - surface_t_) > 0.5 || std::abs(w - surface_w_) > 0.5 ||
        std::abs(h - surface_h_) > 0.5) {
      layout = true;
    }
    surface_l_ = l;
    surface_t_ = t;
    surface_w_ = w;
    surface_h_ = h;
    surface_valid_ = w >= 8 && h >= 8;
  }
  if (HasKey(a, "clipWidth")) {
    const double l = GetDouble(a, "clipLeft", 0), t = GetDouble(a, "clipTop", 0);
    const double w = GetDouble(a, "clipWidth", 0), h = GetDouble(a, "clipHeight", 0);
    if (std::abs(l - clip_l_) > 0.5 || std::abs(t - clip_t_) > 0.5 || std::abs(w - clip_w_) > 0.5 ||
        std::abs(h - clip_h_) > 0.5) {
      layout = true;
    }
    clip_l_ = l;
    clip_t_ = t;
    clip_w_ = w;
    clip_h_ = h;
    clip_valid_ = w >= 1 && h >= 1;
  }

  // 播放态
  if (HasKey(a, "playing")) playing_ = GetBool(a, "playing", playing_);
  if (HasKey(a, "buffering")) buffering_ = GetBool(a, "buffering", buffering_);
  if (HasKey(a, "positionSec")) {
    position_sec_ = GetDouble(a, "positionSec", position_sec_);
    position_tick_ = GetTickCount();
  }
  if (HasKey(a, "durationSec")) duration_sec_ = GetDouble(a, "durationSec", duration_sec_);
  if (HasKey(a, "bufferedSec")) buffered_sec_ = GetDouble(a, "bufferedSec", buffered_sec_);
  if (HasKey(a, "bounded")) bounded_ = GetBool(a, "bounded", bounded_);
  if (HasKey(a, "rate")) rate_ = GetDouble(a, "rate", rate_);
  if (HasKey(a, "volume") && drag_id_ != "volume") volume_ = GetDouble(a, "volume", volume_);
  if (HasKey(a, "gestures")) gestures_ = GetBool(a, "gestures", gestures_);

  // 点播
  set_wstr(title_, "title");
  set_wstr(resolution_, "resolution");
  set_bool(top_visible_, "top");
  set_bool(bottom_visible_, "bottom");
  set_bool(center_visible_, "centerVisible");
  set_bool(episodes_visible_, "episodesVisible");
  if (HasKey(a, "episodes")) episodes_ = GetWideList(a, "episodes");
  if (HasKey(a, "episodeSelected")) episode_selected_ = GetInt(a, "episodeSelected", -1);
  set_wstr(speed_badge_, "speedBadge");
  set_wstr(aspect_badge_, "aspectBadge");
  set_wstr(decode_badge_, "decodeBadge");
  set_wstr(player_badge_, "playerBadge");
  if (HasKey(a, "showPlayer")) show_player_ = GetBool(a, "showPlayer", show_player_);
  if (HasKey(a, "showDirect")) show_direct_ = GetBool(a, "showDirect", show_direct_);
  if (HasKey(a, "directOn")) direct_on_ = GetBool(a, "directOn", direct_on_);
  if (HasKey(a, "showDisc")) show_disc_ = GetBool(a, "showDisc", show_disc_);
  if (HasKey(a, "hasCast")) has_cast_ = GetBool(a, "hasCast", has_cast_);
  if (HasKey(a, "hasMini")) has_mini_ = GetBool(a, "hasMini", has_mini_);
  if (HasKey(a, "openingSec")) opening_sec_ = GetInt(a, "openingSec", opening_sec_);
  if (HasKey(a, "endingSec")) ending_sec_ = GetInt(a, "endingSec", ending_sec_);
  if (HasKey(a, "moreItems")) {
    more_items_ = ParseLineItems(a, "moreItems");
    if (sheet_kind_ == "more") {
      sheet_items_ = more_items_;
      MarkDirty(kSheet);
    }
  }
  set_bool(debug_hud_on_, "debugHud");
  if (HasKey(a, "debugText")) {
    const auto t = DecodeField(GetString(a, "debugText"));
    if (t.size() != debug_text_.size()) layout = true;
    debug_text_ = t;
  }

  // 直播
  if (HasKey(a, "groups")) groups_ = ParseLineItems(a, "groups");
  if (HasKey(a, "groupSelected")) group_selected_ = GetInt(a, "groupSelected", -1);
  if (HasKey(a, "channels")) channels_ = ParseLineItems(a, "channels");
  if (HasKey(a, "channelSelected")) channel_selected_ = GetInt(a, "channelSelected", -1);
  if (HasKey(a, "channelDigits")) channel_digits_ = std::clamp(GetInt(a, "channelDigits", 3), 3, 8);
  if (HasKey(a, "epgDays")) epg_days_ = GetWideList(a, "epgDays");
  if (HasKey(a, "epgDaySelected")) epg_day_selected_ = GetInt(a, "epgDaySelected", 0);
  if (HasKey(a, "programs")) programs_ = ParseLineItems(a, "programs");
  if (HasKey(a, "programSelected")) program_selected_ = GetInt(a, "programSelected", -1);
  set_bool(epg_open_, "epgOpen");
  set_bool(live_left_visible_, "liveLeftVisible");
  set_bool(live_right_visible_, "liveRightVisible");
  set_bool(channel_visible_, "channelVisible");
  if (HasKey(a, "liveRightItems")) live_right_items_ = ParseLineItems(a, "liveRightItems");
  set_wstr(channel_no_, "channelNo");
  set_wstr(channel_name_, "channelName");
  set_wstr(prog_time_, "programTime");
  set_wstr(prog_title_, "programTitle");
  set_wstr(line_label_, "lineLabel");
  if (HasKey(a, "zapDigits")) {
    const auto z = DecodeField(GetString(a, "zapDigits"));
    if (z != zap_digits_) layout = true;
    zap_digits_ = z;
  }
  if (HasKey(a, "liveError")) {
    const auto e = DecodeField(GetString(a, "liveError"));
    if (e != live_error_) layout = true;
    live_error_ = e;
  }
  set_bool(catchup_bar_, "catchupBar");
  set_bool(catchup_seek_, "catchupSeek");
  if (HasKey(a, "pillLabel")) {
    const auto p = DecodeField(GetString(a, "pillLabel"));
    if (p != pill_label_) layout = true;
    pill_label_ = p;
  }
  set_bool(fullscreen_active_, "immersive");
  set_wstr(catchup_scale_, "catchupScale");
  set_wstr(catchup_player_, "catchupPlayer");
  set_wstr(catchup_decode_, "catchupDecode");
  set_wstr(catchup_direct_, "catchupDirect");
  set_wstr(catchup_across_, "catchupAcross");
  set_wstr(catchup_invert_, "catchupInvert");
  set_wstr(catchup_fail_, "catchupFail");

  if (HasKey(a, "bufferText")) {
    const auto t = DecodeField(GetString(a, "bufferText"));
    if (t != buffer_text_) {
      if (buffer_text_.empty()) spin_tick0_ = GetTickCount();
      layout = true;
      buffer_text_ = t;
    }
  }
  if (HasKey(a, "swipeDy")) {
    const double v = GetDouble(a, "swipeDy", 0);
    if (v != swipe_dy_) layout = true;
    swipe_dy_ = v;
  }
  if (HasKey(a, "swipePrev")) {
    const auto t = DecodeField(GetString(a, "swipePrev"));
    if (t != swipe_prev_) layout = true;
    swipe_prev_ = t;
  }
  if (HasKey(a, "swipeNext")) {
    const auto t = DecodeField(GetString(a, "swipeNext"));
    if (t != swipe_next_) layout = true;
    swipe_next_ = t;
  }
  if (HasKey(a, "channelLogo")) channel_logo_ = GetString(a, "channelLogo");

  // HUD（由 Dart 状态推导）
  if (HasKey(a, "hudKind")) {
    const std::string k = GetString(a, "hudKind");
    const std::string ic = GetString(a, "hudIcon");
    uint32_t icon = 0;
    if (ic == "ff") icon = kotv_chrome::icon::kFastForwardRounded;
    else if (ic == "rew") icon = kotv_chrome::icon::kFastRewindRounded;
    else if (ic == "bright") icon = kotv_chrome::icon::kBrightness;
    else if (ic == "volume") icon = kotv_chrome::icon::kVolumeUp;
    HudKind kind = HudKind::None;
    if (k == "text") kind = HudKind::Text;
    else if (k == "side") kind = HudKind::Side;
    else if (k == "seek") kind = HudKind::Seek;
    SetHud(kind, DecodeField(GetString(a, "hudText")), icon, GetDouble(a, "hudSize", 18), GetBool(a, "hudUi", true));
  }

  if (IsMini() && !playing_ && !mini_bar_shown_) {
    mini_bar_shown_ = true;
    layout = true;
  } else if (IsMini() && playing_ && mini_bar_shown_ && HasKey(a, "playing")) {
    if (mini_hover_) {
      if (msg_hwnd_) SetTimer(msg_hwnd_, kTimerMini, kMiniHideMs, nullptr);
    } else {
      mini_bar_shown_ = false;
      layout = true;
    }
  }
  return layout;
}

void Win7ChromeShell::ApplyDanmaku(const ChromeMap& a) {
  if (HasKey(a, "enabled")) danmaku_enabled_ = GetBool(a, "enabled", danmaku_enabled_);
  if (HasKey(a, "fontSize")) danmaku_font_ = GetDouble(a, "fontSize", danmaku_font_);
  if (HasKey(a, "opacity")) danmaku_opacity_ = std::clamp(GetDouble(a, "opacity", danmaku_opacity_), 0.0, 1.0);
  if (HasKey(a, "durationMs")) danmaku_duration_ms_ = std::max(1000, GetInt(a, "durationMs", danmaku_duration_ms_));
  if (HasKey(a, "fixedDurationMs")) danmaku_fixed_ms_ = std::max(500, GetInt(a, "fixedDurationMs", danmaku_fixed_ms_));
  if (HasKey(a, "rows")) danmaku_rows_ = std::max(1, GetInt(a, "rows", danmaku_rows_));
  if (HasKey(a, "maxOnScreen")) danmaku_max_on_screen_ = std::max(1, GetInt(a, "maxOnScreen", danmaku_max_on_screen_));
  if (HasKey(a, "scrollArea")) danmaku_scroll_area_ = std::clamp(GetDouble(a, "scrollArea", danmaku_scroll_area_), 0.1, 1.0);
  if (HasKey(a, "bold")) danmaku_bold_ = GetBool(a, "bold", danmaku_bold_);
  if (HasKey(a, "showScroll")) danmaku_show_scroll_ = GetBool(a, "showScroll", danmaku_show_scroll_);
  if (HasKey(a, "showTop")) danmaku_show_top_ = GetBool(a, "showTop", danmaku_show_top_);
  if (HasKey(a, "showBottom")) danmaku_show_bottom_ = GetBool(a, "showBottom", danmaku_show_bottom_);
  if (HasKey(a, "showReverse")) danmaku_show_reverse_ = GetBool(a, "showReverse", danmaku_show_reverse_);
  if (HasKey(a, "showPositioned")) danmaku_show_positioned_ = GetBool(a, "showPositioned", danmaku_show_positioned_);
  if (HasKey(a, "showSpecial")) danmaku_show_special_ = GetBool(a, "showSpecial", danmaku_show_special_);
  if (HasKey(a, "lineSpacing")) danmaku_line_spacing_ = GetDouble(a, "lineSpacing", danmaku_line_spacing_);
  if (HasKey(a, "strokeMode")) danmaku_stroke_mode_ = GetString(a, "strokeMode");
  if (HasKey(a, "colorMode")) danmaku_color_mode_ = GetString(a, "colorMode");
  if (HasKey(a, "rowsTop")) danmaku_rows_top_ = GetInt(a, "rowsTop", danmaku_rows_top_);
  if (HasKey(a, "rowsBottom")) danmaku_rows_bottom_ = GetInt(a, "rowsBottom", danmaku_rows_bottom_);
  if (HasKey(a, "scrollGap")) danmaku_scroll_gap_ = GetDouble(a, "scrollGap", danmaku_scroll_gap_);
  if (HasKey(a, "strokeWidth")) danmaku_stroke_width_ = GetDouble(a, "strokeWidth", danmaku_stroke_width_);
  if (HasKey(a, "shadowOpacity")) danmaku_shadow_opacity_ = GetDouble(a, "shadowOpacity", danmaku_shadow_opacity_);
  if (HasKey(a, "projectionOffsetX")) danmaku_proj_x_ = GetDouble(a, "projectionOffsetX", danmaku_proj_x_);
  if (HasKey(a, "projectionOffsetY")) danmaku_proj_y_ = GetDouble(a, "projectionOffsetY", danmaku_proj_y_);
  if (HasKey(a, "projectionOpacity")) danmaku_proj_opacity_ = GetDouble(a, "projectionOpacity", danmaku_proj_opacity_);
  if (HasKey(a, "items")) {
    danmaku_items_.clear();
    for (const auto& line : SplitLines(GetString(a, "items"))) {
      if (line.empty()) continue;
      std::vector<std::string> cols;
      size_t cs = 0;
      while (true) {
        const size_t c = line.find('|', cs);
        if (c == std::string::npos) {
          cols.push_back(line.substr(cs));
          break;
        }
        cols.push_back(line.substr(cs, c - cs));
        cs = c + 1;
      }
      while (cols.size() < 9) cols.emplace_back();
      DanmakuItem d;
      d.time = std::strtod(cols[0].c_str(), nullptr);
      d.content = DecodeField(cols[1]);
      d.mode = cols[2].empty() ? 1 : std::atoi(cols[2].c_str());
      d.color = cols[3].empty() ? 0xFFFFFF : std::atoi(cols[3].c_str());
      d.size = cols[4].empty() ? 25 : std::atoi(cols[4].c_str());
      d.pool = std::atoi(cols[5].c_str());
      d.x = std::strtod(cols[6].c_str(), nullptr);
      d.y = std::strtod(cols[7].c_str(), nullptr);
      d.duration_ms = std::atoi(cols[8].c_str());
      if (!d.content.empty()) danmaku_items_.push_back(std::move(d));
    }
    std::sort(danmaku_items_.begin(), danmaku_items_.end(),
              [](const DanmakuItem& x, const DanmakuItem& y) { return x.time < y.time; });
    danmaku_flying_.clear();
    danmaku_cursor_ = 0;
    danmaku_last_sec_ = -1;
  }
  if (enabled_) LayoutDanmaku();
}

void Win7ChromeShell::ApplySheet(const ChromeMap& a) {
  const std::string kind = GetString(a, "kind");
  if (kind.empty()) {
    CloseSheet(false);
    return;
  }
  OpenSheet(kind, DecodeField(GetString(a, "title")), DecodeField(GetString(a, "subtitle")), ParseLineItems(a, "items"));
}

void Win7ChromeShell::HideSheet() { CloseSheet(false); }

// ---------------------------------------------------------------------------
// 弹层
// ---------------------------------------------------------------------------

void Win7ChromeShell::OpenSheet(const std::string& kind, const std::wstring& title, const std::wstring& subtitle,
                                std::vector<LineItem> items) {
  if (kind != sheet_kind_) sheet_scroll_ = 0;
  ClosePopup();
  sheet_kind_ = kind;
  sheet_title_ = title;
  sheet_subtitle_ = subtitle;
  sheet_items_ = std::move(items);
  if (!pointer_hold_) EmitPointerHold(true);
  LayoutSheet();
}

void Win7ChromeShell::CloseSheet(bool emit) {
  if (sheet_kind_.empty()) return;
  const std::string kind = sheet_kind_;
  if (hold_btn_down_) {
    hold_btn_down_ = false;
    Emit({{"type", Str("fxPreview")}, {"kind", Str(kind)}, {"on", ChromeValue(false)}});
  }
  sheet_kind_.clear();
  sheet_items_.clear();
  sheet_scroll_ = 0;
  if (drag_panel_ == kSheet) {
    drag_panel_ = kPanelCount;
    drag_id_.clear();
  }
  ShowPanel(kSheet, false, RECT{});
  if (emit) Emit({{"type", Str("sheetClose")}, {"kind", Str(kind)}});
  EmitPointerHold(false);
}

void Win7ChromeShell::OpenFullscreenPopup(const RECT& anchor_host) {
  popup_anchor_ = anchor_host;
  popup_open_ = true;
  panels_[kPopup].dirty = true;
  ShowPanel(kPopup, true, HostClient());
}

void Win7ChromeShell::ClosePopup() {
  if (!popup_open_) return;
  popup_open_ = false;
  ShowPanel(kPopup, false, RECT{});
}

void Win7ChromeShell::SetVolumeExpanded(bool on) {
  if (on == volume_expanded_) return;
  volume_expanded_ = on;
  MarkDirty(kBottom);
}

// ---------------------------------------------------------------------------
// 事件
// ---------------------------------------------------------------------------

void Win7ChromeShell::Emit(ChromeMap map) {
  if (event_fn_) event_fn_(std::move(map));
}

void Win7ChromeShell::EmitPointerHold(bool on) {
  if (on == pointer_hold_) return;
  pointer_hold_ = on;
  Emit({{"type", Str("pointerHold")}, {"on", ChromeValue(on)}});
}

void Win7ChromeShell::EmitSlider(const std::string& id, double value, bool commit) {
  Emit({{"type", Str("slider")}, {"id", Str(id)}, {"value", ChromeValue(value)}, {"commit", ChromeValue(commit)},
        {"kind", Str(sheet_kind_)}});
}

void Win7ChromeShell::EmitPointer(const char* phase, int host_x, int host_y, double dx, double dy, bool shift) {
  Emit({{"type", Str("pointer")},
        {"phase", Str(phase)},
        {"x", ChromeValue(host_x / dpr_)},
        {"y", ChromeValue(host_y / dpr_)},
        {"dx", ChromeValue(dx)},
        {"dy", ChromeValue(dy)},
        {"shift", ChromeValue(shift)}});
}

// ---------------------------------------------------------------------------
// 窗口过程
// ---------------------------------------------------------------------------

namespace {
template <typename T>
T* SelfOf(HWND hwnd, UINT msg, LPARAM lp) {
  if (msg == WM_NCCREATE) {
    auto* cs = reinterpret_cast<CREATESTRUCTW*>(lp);
    SetWindowLongPtrW(hwnd, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(cs->lpCreateParams));
  }
  return reinterpret_cast<T*>(GetWindowLongPtrW(hwnd, GWLP_USERDATA));
}
}  // namespace

LRESULT CALLBACK Win7ChromeShell::PanelWndProc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
  auto* self = SelfOf<Win7ChromeShell>(hwnd, msg, lp);
  if (self) return self->OnPanel(hwnd, msg, wp, lp);
  return DefWindowProcW(hwnd, msg, wp, lp);
}

LRESULT CALLBACK Win7ChromeShell::GestureWndProc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
  auto* self = SelfOf<Win7ChromeShell>(hwnd, msg, lp);
  if (self) return self->OnGesture(hwnd, msg, wp, lp);
  return DefWindowProcW(hwnd, msg, wp, lp);
}

LRESULT CALLBACK Win7ChromeShell::MsgWndProc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
  auto* self = SelfOf<Win7ChromeShell>(hwnd, msg, lp);
  if (self) {
    if (msg == kMsgRender) {
      self->RenderDirty();
      return 0;
    }
    if (msg == WM_TIMER) {
      self->OnTimer(wp);
      return 0;
    }
  }
  return DefWindowProcW(hwnd, msg, wp, lp);
}

LRESULT CALLBACK Win7ChromeShell::DanmakuWndProc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
  SelfOf<Win7ChromeShell>(hwnd, msg, lp);
  if (msg == WM_NCHITTEST) return HTTRANSPARENT;
  if (msg == WM_MOUSEACTIVATE) return MA_NOACTIVATE;
  return DefWindowProcW(hwnd, msg, wp, lp);
}

LRESULT CALLBACK Win7ChromeShell::HostSubclassProc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp, UINT_PTR,
                                                   DWORD_PTR data) {
  auto* self = reinterpret_cast<Win7ChromeShell*>(data);
  if (!self || !self->enabled_) return DefSubclassProc(hwnd, msg, wp, lp);
  switch (msg) {
    case WM_SIZE:
    case WM_SHOWWINDOW: {
      const LRESULT r = DefSubclassProc(hwnd, msg, wp, lp);
      self->Layout();
      return r;
    }
    case WM_MOUSEWHEEL:
      if (self->RouteWheel(wp, lp)) return 0;
      break;
    case WM_KEYDOWN:
    case WM_SYSKEYDOWN:
    case WM_KEYUP:
    case WM_SYSKEYUP:
      if (self->HandleKey(msg, wp, lp)) return 0;
      break;
    case WM_APPCOMMAND: {
      if (self->suspended_ || self->mode_.empty() || self->mode_ == "vod_inline") break;
      const char* name = AppCommandToLogicalName(GET_APPCOMMAND_LPARAM(lp));
      if (name) {
        self->Emit({{"type", Str("key")}, {"logical", Str(name)}, {"down", ChromeValue(true)},
                    {"repeat", ChromeValue(false)}, {"up", ChromeValue(false)}});
        self->Emit({{"type", Str("key")}, {"logical", Str(name)}, {"down", ChromeValue(false)},
                    {"repeat", ChromeValue(false)}, {"up", ChromeValue(true)}});
        return TRUE;
      }
      break;
    }
    default:
      break;
  }
  return DefSubclassProc(hwnd, msg, wp, lp);
}

LRESULT CALLBACK Win7ChromeShell::RootSubclassProc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp, UINT_PTR,
                                                   DWORD_PTR data) {
  auto* self = reinterpret_cast<Win7ChromeShell*>(data);
  if (msg == WM_MOUSEWHEEL && self && self->enabled_ && self->RouteWheel(wp, lp)) return 0;
  const LRESULT r = DefSubclassProc(hwnd, msg, wp, lp);
  if (self && self->enabled_ && (msg == WM_MOVE || msg == WM_WINDOWPOSCHANGED)) {
    self->Layout();
  }
  return r;
}

// Win7 滚轮发给焦点窗（宿主或根窗），这里按光标位置转给面板或手势层。
// 画面区上方是 mpv 视频子窗，WindowFromPoint 拿不到手势层，所以全屏/直播按手势层矩形判定。
bool Win7ChromeShell::RouteWheel(WPARAM wp, LPARAM lp) {
  if (suspended_ || mode_.empty()) return false;
  POINT pt{GET_X_LPARAM(lp), GET_Y_LPARAM(lp)};
  HWND target = WindowFromPoint(pt);
  const PanelId pid = PanelOf(target);
  if (pid != kPanelCount) {
    ScreenToClient(target, &pt);
    OnWheel(pid, GET_WHEEL_DELTA_WPARAM(wp), pt.x, pt.y);
    return true;
  }
  if (!gesture_hwnd_ || !IsWindowVisible(gesture_hwnd_)) return false;
  bool to_gesture = target == gesture_hwnd_;
  if (!to_gesture && (mode_ == "vod" || mode_ == "live") && sheet_kind_.empty() && !popup_open_) {
    RECT g{};
    GetWindowRect(gesture_hwnd_, &g);
    to_gesture = PtInRect(&g, pt) && target && GetAncestor(target, GA_ROOT) == RootHwnd();
  }
  if (!to_gesture) return false;
  SendMessageW(gesture_hwnd_, WM_MOUSEWHEEL, wp, lp);
  return true;
}

Win7ChromeShell::PanelId Win7ChromeShell::PanelOf(HWND hwnd) const {
  if (!hwnd) return kPanelCount;
  for (int i = 0; i < kPanelCount; ++i) {
    if (panels_[i].hwnd == hwnd) return static_cast<PanelId>(i);
  }
  return kPanelCount;
}

const Win7ChromeShell::Hit* Win7ChromeShell::HitAt(PanelId id, int x, int y) const {
  const auto& hits = panels_[id].hits;
  for (auto it = hits.rbegin(); it != hits.rend(); ++it) {
    POINT pt{x, y};
    if (PtInRect(&it->rc, pt)) return &*it;
  }
  return nullptr;
}

bool Win7ChromeShell::HandleKey(UINT msg, WPARAM wp, LPARAM lp) {
  if (suspended_ || mode_.empty() || mode_ == "vod_inline") return false;
  const bool down = msg == WM_KEYDOWN || msg == WM_SYSKEYDOWN;
  if (!sheet_kind_.empty()) {
    if (down && (wp == VK_ESCAPE || wp == VK_BACK)) CloseSheet(true);
    if (down && (wp == VK_UP || wp == VK_DOWN || wp == VK_PRIOR || wp == VK_NEXT)) {
      const int step = (wp == VK_PRIOR || wp == VK_NEXT) ? P(240) : P(52);
      sheet_scroll_ += (wp == VK_UP || wp == VK_PRIOR) ? -step : step;
      MarkDirty(kSheet);
    }
    return true;
  }
  if (popup_open_) {
    if (down && (wp == VK_ESCAPE || wp == VK_BACK)) ClosePopup();
    return true;
  }
  const char* name = VkToLogicalName(wp);
  if (!name) return false;
  const bool repeat = down && (lp & (1 << 30)) != 0;
  Emit({{"type", Str("key")}, {"logical", Str(name)}, {"down", ChromeValue(down && !repeat)},
        {"repeat", ChromeValue(repeat)}, {"up", ChromeValue(!down)}});
  return true;
}

// ---------------------------------------------------------------------------
// 面板输入
// ---------------------------------------------------------------------------

LRESULT Win7ChromeShell::OnPanel(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
  const PanelId pid = PanelOf(hwnd);
  switch (msg) {
    case WM_MOUSEACTIVATE:
      return MA_NOACTIVATE;
    case WM_NCHITTEST:
      if (pid != kPanelCount && panels_[pid].click_through) return HTTRANSPARENT;
      return HTCLIENT;
    case WM_SETCURSOR:
      SetCursor(LoadCursor(nullptr, IDC_ARROW));
      return TRUE;
    case WM_MOUSEMOVE: {
      if (pid == kPanelCount) break;
      last_move_pos_ = GetMessagePos();
      const int x = GET_X_LPARAM(lp);
      const int y = GET_Y_LPARAM(lp);
      if (!panel_hover_[pid]) {
        panel_hover_[pid] = true;
        TRACKMOUSEEVENT tme{static_cast<DWORD>(sizeof(TRACKMOUSEEVENT)), TME_LEAVE, hwnd, 0};
        TrackMouseEvent(&tme);
        if (pid != kSheet && pid != kPopup) EmitPointerHold(true);
      }
      if (IsMini() && pid == kBottom) {
        mini_hover_ = true;
        if (msg_hwnd_) SetTimer(msg_hwnd_, kTimerMini, kMiniHideMs, nullptr);
      }
      if (!drag_id_.empty() && drag_panel_ == pid && GetCapture() == hwnd) {
        Hit h{drag_id_, drag_rc_, drag_index_};
        OnHitDrag(pid, h, x, y);
        return 0;
      }
      if (pid == kBottom) {
        const Hit* h = HitAt(pid, x, y);
        const bool over_vol = h && (h->id == "volIcon" || h->id == "volume");
        if (over_vol) {
          volume_hover_ = true;
          if (msg_hwnd_) KillTimer(msg_hwnd_, kTimerVolume);
          SetVolumeExpanded(true);
        } else if (volume_hover_) {
          volume_hover_ = false;
          if (msg_hwnd_) SetTimer(msg_hwnd_, kTimerVolume, kVolumeCollapseMs, nullptr);
        }
      }
      return 0;
    }
    case WM_MOUSELEAVE: {
      if (pid == kPanelCount) break;
      panel_hover_[pid] = false;
      if (pid == kBottom && volume_hover_) {
        volume_hover_ = false;
        if (msg_hwnd_) SetTimer(msg_hwnd_, kTimerVolume, kVolumeCollapseMs, nullptr);
      }
      bool any = false;
      for (int i = 0; i < kPanelCount; ++i) {
        if (i != kSheet && i != kPopup) any = any || panel_hover_[i];
      }
      if (!any && drag_id_.empty() && sheet_kind_.empty()) EmitPointerHold(false);
      if (IsMini() && pid == kBottom) {
        POINT pt{};
        GetCursorPos(&pt);
        if (WindowFromPoint(pt) != gesture_hwnd_) {
          mini_hover_ = false;
          if (playing_ && mini_bar_shown_) {
            mini_bar_shown_ = false;
            Layout();
          }
        }
      }
      return 0;
    }
    case WM_LBUTTONDOWN:
    case WM_LBUTTONDBLCLK: {
      if (pid == kPanelCount) break;
      const int x = GET_X_LPARAM(lp);
      const int y = GET_Y_LPARAM(lp);
      const Hit* h = HitAt(pid, x, y);
      if (!h) {
        if (pid == kSheet) {
          POINT pt{x, y};
          if (!PtInRect(&sheet_card_, pt)) CloseSheet(true);
        } else if (pid == kPopup) {
          ClosePopup();
        }
        return 0;
      }
      SetCapture(hwnd);
      drag_panel_ = pid;
      drag_id_ = h->id;
      drag_rc_ = h->rc;
      drag_index_ = h->index;
      const Hit copy = *h;
      OnHitDown(pid, copy, x, y);
      return 0;
    }
    case WM_LBUTTONUP: {
      if (pid == kPanelCount) break;
      if (drag_id_.empty() || drag_panel_ != pid) return 0;
      const int x = GET_X_LPARAM(lp);
      const int y = GET_Y_LPARAM(lp);
      const Hit h{drag_id_, drag_rc_, drag_index_};
      drag_id_.clear();
      drag_panel_ = kPanelCount;
      if (GetCapture() == hwnd) ReleaseCapture();
      if (msg_hwnd_) KillTimer(msg_hwnd_, kTimerLongPress);
      POINT pt{x, y};
      OnHitUp(pid, h, x, y, PtInRect(&h.rc, pt) != FALSE);
      return 0;
    }
    case WM_CAPTURECHANGED: {
      if (!drag_id_.empty() && drag_panel_ == pid) {
        const Hit h{drag_id_, drag_rc_, drag_index_};
        drag_id_.clear();
        drag_panel_ = kPanelCount;
        if (msg_hwnd_) KillTimer(msg_hwnd_, kTimerLongPress);
        OnHitUp(pid, h, -1, -1, false);
      }
      return 0;
    }
    case WM_RBUTTONUP:
      if (pid == kSheet) {
        CloseSheet(true);
      } else if (pid == kPopup) {
        ClosePopup();
      } else {
        Emit({{"type", Str("back")}});
      }
      return 0;
    case WM_MOUSEWHEEL: {
      if (pid == kPanelCount) break;
      POINT pt{GET_X_LPARAM(lp), GET_Y_LPARAM(lp)};
      ScreenToClient(hwnd, &pt);
      OnWheel(pid, GET_WHEEL_DELTA_WPARAM(wp), pt.x, pt.y);
      return 0;
    }
    case WM_PAINT: {
      PAINTSTRUCT ps;
      BeginPaint(hwnd, &ps);
      EndPaint(hwnd, &ps);
      return 0;
    }
    case WM_ERASEBKGND:
      return 1;
    default:
      break;
  }
  return DefWindowProcW(hwnd, msg, wp, lp);
}

void Win7ChromeShell::OnWheel(PanelId pid, int delta, int x, int y) {
  const int step = -static_cast<int>(std::lround(delta / 120.0 * 3 * 20 * dpr_));
  switch (pid) {
    case kEpisodes:
      episode_scroll_ += step;
      MarkDirty(kEpisodes);
      break;
    case kLiveRight:
      right_scroll_ += step;
      MarkDirty(kLiveRight);
      break;
    case kSheet:
      sheet_scroll_ += step;
      MarkDirty(kSheet);
      break;
    case kLiveLeft: {
      for (const auto& h : panels_[kLiveLeft].hits) {
        POINT pt{x, y};
        if (h.id.rfind("col:", 0) != 0 || !PtInRect(&h.rc, pt)) continue;
        if (h.id == "col:group") group_scroll_ += step;
        else if (h.id == "col:channel") channel_scroll_ += step;
        else if (h.id == "col:epg") program_scroll_ += step;
        else if (h.id == "col:days") day_scroll_ += step;
        MarkDirty(kLiveLeft);
        break;
      }
      break;
    }
    default:
      break;
  }
}

void Win7ChromeShell::OnTimer(UINT_PTR id) {
  switch (id) {
    case kTimerVolume:
      KillTimer(msg_hwnd_, kTimerVolume);
      if (!volume_hover_ && drag_id_ != "volume") SetVolumeExpanded(false);
      break;
    case kTimerMini:
      KillTimer(msg_hwnd_, kTimerMini);
      if (IsMini() && playing_ && mini_bar_shown_) {
        mini_bar_shown_ = false;
        Layout();
      }
      break;
    case kTimerLongPress:
      KillTimer(msg_hwnd_, kTimerLongPress);
      if (drag_id_ == "speed") {
        drag_id_ = "speed:held";
        Emit({{"type", Str("speedSheet")}});
      } else if (drag_id_ == "channel") {
        drag_id_ = "channel:held";
        Emit({{"type", Str("channelFav")}, {"index", Int(drag_index_)}});
      }
      break;
    case kTimerGestureHold:
      KillTimer(msg_hwnd_, kTimerGestureHold);
      if (ges_down_ && !ges_hold_fired_) {
        ges_hold_fired_ = true;
        Emit({{"type", Str("holdSpeed")}, {"on", ChromeValue(true)}});
      }
      break;
    case kTimerClock:
      MarkDirty(kBottom);
      break;
    case kTimerDanmaku:
      PaintDanmaku();
      break;
    case kTimerSpin:
      MarkDirty(kBuffer);
      break;
    case kTimerMarquee:
      for (int i = 0; i < kPanelCount; ++i) {
        if ((marquee_panels_ & (1u << i)) && panels_[i].shown) MarkDirty(static_cast<PanelId>(i));
      }
      UpdateMarqueeTimer();
      break;
    default:
      break;
  }
}

static double SliderFrac(const RECT& rc, int inset, int x) {
  const double w = std::max(1.0, static_cast<double>(rc.right - rc.left - inset * 2));
  return std::clamp((x - rc.left - inset) / w, 0.0, 1.0);
}

void Win7ChromeShell::OnHitDown(PanelId pid, const Hit& hit, int x, int y) {
  (void)y;
  const std::string& id = hit.id;
  if (id == "seek" || id == "catchupSeek") {
    const int inset = (hit.rc.bottom - hit.rc.top) / 2;
    drag_value_ = SliderFrac(hit.rc, inset, x);
    if (TotalSec() > 0) position_sec_ = drag_value_ * TotalSec();
    position_tick_ = GetTickCount();
    Emit({{"type", Str("seekFraction")}, {"value", ChromeValue(drag_value_)}, {"commit", ChromeValue(false)}});
    MarkDirty(pid);
    return;
  }
  if (id == "volume") {
    const int inset = (hit.rc.bottom - hit.rc.top) / 2;
    volume_ = std::clamp(1.0 + SliderFrac(hit.rc, inset, x) * 99.0, 1.0, 100.0);
    EmitSlider("volume", std::round(volume_), false);
    MarkDirty(pid);
    return;
  }
  if (id == "rightVolume") {
    const int inset = P(14);
    volume_ = std::round(std::clamp(1.0 + SliderFrac(hit.rc, inset, x) * 99.0, 1.0, 100.0));
    EmitSlider("volume", volume_, false);
    MarkDirty(pid);
    return;
  }
  if (id == "sheetSlider" && hit.index >= 0 && hit.index < static_cast<int>(sheet_items_.size())) {
    auto& it = sheet_items_[hit.index];
    const int inset = it.kind == "sliderInline" ? P(24) : P(14);
    const double frac = SliderFrac(hit.rc, inset, x);
    it.slider_value = Snap(it.slider_min + frac * (it.slider_max - it.slider_min), it);
    for (auto& big : sheet_items_) {
      if (big.kind == "big" && big.id == it.id) big.label = FormatValue(it.sub, it.slider_value);
    }
    it.trailing = FormatValue(it.sub, it.slider_value);
    EmitSlider(it.id, it.slider_value, false);
    MarkDirty(kSheet);
    return;
  }
  if (id == "sheetHold" && hit.index >= 0) {
    hold_btn_down_ = true;
    Emit({{"type", Str("fxPreview")}, {"kind", Str(sheet_kind_)}, {"on", ChromeValue(true)}});
    MarkDirty(kSheet);
    return;
  }
  if (id == "speed" || id == "channel") {
    if (msg_hwnd_) SetTimer(msg_hwnd_, kTimerLongPress, kLongPressMs, nullptr);
  }
}

void Win7ChromeShell::OnHitDrag(PanelId pid, const Hit& hit, int x, int y) {
  (void)y;
  const std::string& id = hit.id;
  if (id == "seek" || id == "catchupSeek") {
    const int inset = (hit.rc.bottom - hit.rc.top) / 2;
    drag_value_ = SliderFrac(hit.rc, inset, x);
    if (TotalSec() > 0) position_sec_ = drag_value_ * TotalSec();
    position_tick_ = GetTickCount();
    Emit({{"type", Str("seekFraction")}, {"value", ChromeValue(drag_value_)}, {"commit", ChromeValue(false)}});
    MarkDirty(pid);
  } else if (id == "volume" || id == "rightVolume") {
    const int inset = id == "volume" ? (hit.rc.bottom - hit.rc.top) / 2 : P(14);
    volume_ = std::round(std::clamp(1.0 + SliderFrac(hit.rc, inset, x) * 99.0, 1.0, 100.0));
    EmitSlider("volume", volume_, false);
    MarkDirty(pid);
  } else if (id == "sheetSlider") {
    OnHitDown(pid, hit, x, y);
  }
}

void Win7ChromeShell::OnHitUp(PanelId pid, const Hit& hit, int x, int y, bool inside) {
  (void)y;
  const std::string& id = hit.id;
  if (id == "seek" || id == "catchupSeek") {
    Emit({{"type", Str("seekFraction")}, {"value", ChromeValue(drag_value_)}, {"commit", ChromeValue(true)}});
    return;
  }
  if (id == "volume" || id == "rightVolume") {
    EmitSlider("volume", std::round(volume_), true);
    return;
  }
  if (id == "sheetSlider") {
    if (hit.index >= 0 && hit.index < static_cast<int>(sheet_items_.size())) {
      EmitSlider(sheet_items_[hit.index].id, sheet_items_[hit.index].slider_value, true);
    }
    return;
  }
  if (id == "sheetHold") {
    if (hold_btn_down_) {
      hold_btn_down_ = false;
      Emit({{"type", Str("fxPreview")}, {"kind", Str(sheet_kind_)}, {"on", ChromeValue(false)}});
      MarkDirty(kSheet);
    }
    return;
  }
  if (!inside || id == "speed:held" || id == "channel:held") return;

  if (pid == kSheet) {
    OnSheetTap(hit, x);
    return;
  }
  if (pid == kPopup) {
    ClosePopup();
    Emit({{"type", Str("sheet")}, {"kind", Str("fullscreenKind")}, {"id", Str(id)}});
    return;
  }
  if (id == "volIcon") {
    SetVolumeExpanded(!volume_expanded_);
    return;
  }
  if (id == "expand") {
    if (IsLive()) {
      Emit({{"type", Str("liveRight")}, {"id", Str("fullscreen")}});
      return;
    }
    RECT a = hit.rc;
    OffsetRect(&a, panels_[pid].rc.left, panels_[pid].rc.top);
    OpenFullscreenPopup(a);
    return;
  }
  if (id == "more") {
    if (!more_items_.empty()) OpenSheet("more", L"", L"", more_items_);
    return;
  }
  if (id == "closeEpisodes") {
    Emit({{"type", Str("closeEpisodes")}});
    return;
  }
  if (id == "episode") {
    Emit({{"type", Str("episode")}, {"index", Int(hit.index)}});
    return;
  }
  if (id == "subtitle" || id == "audio" || id == "video" || id == "disc") {
    Emit({{"type", Str("track")}, {"kind", Str(id)}, {"id", Str("open")}});
    return;
  }
  if (id.rfind("offset:", 0) == 0) {
    Emit({{"type", Str("offsets")}, {"op", Str(id.substr(7))}});
    return;
  }
  if (id == "group" || id == "channel" || id == "epgDay" || id == "epg") {
    Emit({{"type", Str(id)}, {"index", Int(hit.index)}});
    return;
  }
  if (id == "epgTab") {
    Emit({{"type", Str("epgToggle")}, {"open", ChromeValue(!epg_open_)}});
    return;
  }
  if (id.rfind("right:", 0) == 0) {
    Emit({{"type", Str("liveRight")}, {"id", Str(id.substr(6))}});
    return;
  }
  if (id == "mini" && IsMini()) {
    Emit({{"type", Str("mini")}});
    return;
  }
  // toggle / stop / cast / mini / prev / next / replay / speed / aspect / decode / direct /
  // player / episodes / exit / pill
  Emit({{"type", Str(id)}});
}

void Win7ChromeShell::OnSheetTap(const Hit& hit, int x) {
  (void)x;
  if (hit.index < 0 || hit.index >= static_cast<int>(sheet_items_.size())) return;
  LineItem& it = sheet_items_[hit.index];
  const std::string kind = sheet_kind_;
  const std::string& k = it.kind;
  if (k == "toggle" || k == "switch") {
    it.on = !it.on;
    MarkDirty(kSheet);
    Emit({{"type", Str("toggleItem")}, {"id", Str(it.id)}, {"on", ChromeValue(it.on)}, {"kind", Str(kind)}});
    return;
  }
  if (k == "chip") {
    for (auto& o : sheet_items_) {
      if (o.kind == "chip") o.selected = &o == &it;
    }
    MarkDirty(kSheet);
    Emit({{"type", Str("sheet")}, {"kind", Str(kind)}, {"id", Str(it.id)}});
    return;
  }
  if (k == "button" || k == "cycle") {
    Emit({{"type", Str("sheet")}, {"kind", Str(kind)}, {"id", Str(it.id)}});
    return;
  }
  if (k == "header" || k == "info" || k == "text" || k == "big" || k == "slider" || k == "sliderInline" ||
      k == "hold") {
    return;
  }
  const std::string id = it.id;
  CloseSheet(false);
  if (kind == "player") {
    Emit({{"type", Str("pickPlayer")}, {"id", Str(id)}});
  } else if (IsTrackKind(kind)) {
    Emit({{"type", Str("track")}, {"kind", Str(kind)}, {"id", Str(id)}});
  } else {
    Emit({{"type", Str("sheet")}, {"kind", Str(kind)}, {"id", Str(id)}});
  }
}

// ---------------------------------------------------------------------------
// 画面手势层：指针原样转给 Dart
// ---------------------------------------------------------------------------

LRESULT Win7ChromeShell::OnGesture(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
  auto to_host = [&](int x, int y) {
    POINT pt{x, y};
    MapWindowPoints(hwnd, host_hwnd_, &pt, 1);
    return pt;
  };
  switch (msg) {
    case WM_PAINT: {
      PAINTSTRUCT ps;
      HDC dc = BeginPaint(hwnd, &ps);
      FillRect(dc, &ps.rcPaint, static_cast<HBRUSH>(GetStockObject(BLACK_BRUSH)));
      EndPaint(hwnd, &ps);
      return 0;
    }
    case WM_ERASEBKGND:
      return 1;
    case WM_SETCURSOR:
      SetCursor(LoadCursor(nullptr, IDC_ARROW));
      return TRUE;
    case WM_LBUTTONDOWN:
    case WM_LBUTTONDBLCLK: {
      if (!sheet_kind_.empty()) {
        CloseSheet(true);
        return 0;
      }
      SetCapture(hwnd);
      ges_down_ = true;
      ges_hold_fired_ = false;
      ges_down_pt_ = POINT{GET_X_LPARAM(lp), GET_Y_LPARAM(lp)};
      if (IsMini()) return 0;
      const POINT h = to_host(ges_down_pt_.x, ges_down_pt_.y);
      EmitPointer("down", h.x, h.y);
      if (mode_ == "vod" && gestures_ && msg_hwnd_) SetTimer(msg_hwnd_, kTimerGestureHold, kLongPressMs, nullptr);
      return 0;
    }
    case WM_MOUSEMOVE: {
      const int x = GET_X_LPARAM(lp);
      const int y = GET_Y_LPARAM(lp);
      const POINT h = to_host(x, y);
      if (!ges_tracking_) {
        ges_tracking_ = true;
        TRACKMOUSEEVENT tme{static_cast<DWORD>(sizeof(TRACKMOUSEEVENT)), TME_LEAVE, hwnd, 0};
        TrackMouseEvent(&tme);
      }
      const DWORD pos = GetMessagePos();
      if (!ges_down_ && pos == last_move_pos_) return 0;
      last_move_pos_ = pos;
      const double dist = std::hypot(static_cast<double>(x - ges_down_pt_.x), static_cast<double>(y - ges_down_pt_.y));
      if (IsMini()) {
        mini_hover_ = true;
        if (!mini_bar_shown_) {
          mini_bar_shown_ = true;
          Layout();
        }
        if (msg_hwnd_) SetTimer(msg_hwnd_, kTimerMini, kMiniHideMs, nullptr);
        if (ges_down_ && dist > kTouchSlop * dpr_) {
          ges_down_ = false;
          ReleaseCapture();
          SendMessageW(RootHwnd(), WM_NCLBUTTONDOWN, HTCAPTION, 0);
        }
        return 0;
      }
      if (ges_down_) {
        if (!ges_hold_fired_ && dist > kTouchSlop * dpr_ && msg_hwnd_) KillTimer(msg_hwnd_, kTimerGestureHold);
        EmitPointer("move", h.x, h.y);
      } else {
        EmitPointer("hover", h.x, h.y);
      }
      return 0;
    }
    case WM_LBUTTONUP: {
      if (!ges_down_) return 0;
      ges_down_ = false;
      if (GetCapture() == hwnd) ReleaseCapture();
      if (msg_hwnd_) KillTimer(msg_hwnd_, kTimerGestureHold);
      if (IsMini()) return 0;
      const POINT h = to_host(GET_X_LPARAM(lp), GET_Y_LPARAM(lp));
      EmitPointer("up", h.x, h.y);
      if (ges_hold_fired_) {
        ges_hold_fired_ = false;
        Emit({{"type", Str("holdSpeed")}, {"on", ChromeValue(false)}});
      }
      return 0;
    }
    case WM_CAPTURECHANGED:
      if (ges_down_) {
        ges_down_ = false;
        if (msg_hwnd_) KillTimer(msg_hwnd_, kTimerGestureHold);
        if (!IsMini()) {
          const POINT h = to_host(ges_down_pt_.x, ges_down_pt_.y);
          EmitPointer("cancel", h.x, h.y);
        }
        if (ges_hold_fired_) {
          ges_hold_fired_ = false;
          Emit({{"type", Str("holdSpeed")}, {"on", ChromeValue(false)}});
        }
      }
      return 0;
    case WM_RBUTTONUP:
      Emit({{"type", Str("back")}});
      return 0;
    case WM_MOUSELEAVE: {
      ges_tracking_ = false;
      POINT pt{};
      GetCursorPos(&pt);
      HWND under = WindowFromPoint(pt);
      const bool ours = PanelOf(under) != kPanelCount;
      if (IsMini()) {
        if (!ours) {
          mini_hover_ = false;
          if (playing_ && mini_bar_shown_) {
            mini_bar_shown_ = false;
            Layout();
          }
        }
        return 0;
      }
      if (!ours) {
        POINT h = pt;
        ScreenToClient(host_hwnd_, &h);
        EmitPointer("exit", h.x, h.y);
      }
      return 0;
    }
    case WM_MOUSEWHEEL: {
      if (IsMini()) return 0;
      POINT pt{GET_X_LPARAM(lp), GET_Y_LPARAM(lp)};
      ScreenToClient(host_hwnd_, &pt);
      UINT lines = 3;
      SystemParametersInfoW(SPI_GETWHEELSCROLLLINES, 0, &lines, 0);
      const double dy = -(GET_WHEEL_DELTA_WPARAM(wp) / 120.0) * lines * 20.0;
      EmitPointer("scroll", pt.x, pt.y, 0, dy, (GetKeyState(VK_SHIFT) & 0x8000) != 0);
      return 0;
    }
    default:
      break;
  }
  return DefWindowProcW(hwnd, msg, wp, lp);
}
