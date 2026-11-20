#include "kotv_win_chrome.h"

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>
#include <flutter_windows.h>

#include <algorithm>
#include <cmath>
#include <memory>
#include <sstream>

namespace {

constexpr wchar_t kClass[] = L"KotvWinChromePanel";
constexpr wchar_t kDanmakuClass[] = L"KotvWinChromeDanmaku";
constexpr wchar_t kModalClass[] = L"KotvWinChromeModal";
constexpr int kTopH = 56;
constexpr int kBottomH = 108;
constexpr int kInlineBottomH = 78;
constexpr int kEpW = 280;
constexpr int kLiveLeftW = 520;
constexpr int kLiveRightW = 220;
constexpr int kChannelH = 48;
constexpr int kCenterSz = 72;
constexpr int kModalW = 320;
constexpr int kModalMaxH = 520;
constexpr COLORREF kPink = RGB(229, 45, 39);       // #E52D27
constexpr COLORREF kPinkMuted = RGB(180, 90, 110);
constexpr COLORREF kPanelDark = RGB(18, 10, 28);    // #120A1C
constexpr COLORREF kBarDark = RGB(12, 8, 18);
constexpr COLORREF kBarAlpha = RGB(28, 20, 36);
constexpr COLORREF kDanmakuKey = RGB(1, 0, 1);
constexpr COLORREF kSheetLight = RGB(248, 246, 250);
constexpr COLORREF kGreenOn = RGB(52, 199, 89);

std::wstring Utf8ToWide(const std::string& utf8) {
  if (utf8.empty()) return L"";
  const int n = MultiByteToWideChar(CP_UTF8, 0, utf8.c_str(), -1, nullptr, 0);
  if (n <= 0) return L"";
  std::wstring out(static_cast<size_t>(n - 1), L'\0');
  MultiByteToWideChar(CP_UTF8, 0, utf8.c_str(), -1, out.data(), n);
  return out;
}

std::string GetString(const flutter::EncodableMap& m, const char* key) {
  const auto it = m.find(flutter::EncodableValue(key));
  if (it == m.end() || !std::holds_alternative<std::string>(it->second)) return {};
  return std::get<std::string>(it->second);
}

bool GetBool(const flutter::EncodableMap& m, const char* key, bool def = false) {
  const auto it = m.find(flutter::EncodableValue(key));
  if (it == m.end() || !std::holds_alternative<bool>(it->second)) return def;
  return std::get<bool>(it->second);
}

double GetDouble(const flutter::EncodableMap& m, const char* key, double def = 0) {
  const auto it = m.find(flutter::EncodableValue(key));
  if (it == m.end()) return def;
  if (std::holds_alternative<double>(it->second)) return std::get<double>(it->second);
  if (std::holds_alternative<int32_t>(it->second)) return std::get<int32_t>(it->second);
  if (std::holds_alternative<int64_t>(it->second))
    return static_cast<double>(std::get<int64_t>(it->second));
  return def;
}

int GetInt(const flutter::EncodableMap& m, const char* key, int def = 0) {
  return static_cast<int>(GetDouble(m, key, def));
}

std::vector<std::wstring> GetStringList(const flutter::EncodableMap& m, const char* key) {
  std::vector<std::wstring> out;
  const auto it = m.find(flutter::EncodableValue(key));
  if (it == m.end() || !std::holds_alternative<flutter::EncodableList>(it->second)) return out;
  for (const auto& v : std::get<flutter::EncodableList>(it->second)) {
    if (std::holds_alternative<std::string>(v)) out.push_back(Utf8ToWide(std::get<std::string>(v)));
  }
  return out;
}

std::vector<std::string> GetUtf8List(const flutter::EncodableMap& m, const char* key) {
  std::vector<std::string> out;
  const auto it = m.find(flutter::EncodableValue(key));
  if (it == m.end() || !std::holds_alternative<flutter::EncodableList>(it->second)) return out;
  for (const auto& v : std::get<flutter::EncodableList>(it->second)) {
    if (std::holds_alternative<std::string>(v)) out.push_back(std::get<std::string>(v));
  }
  return out;
}

std::vector<KotvWinChrome::LineItem> ParseLineItems(const flutter::EncodableMap& m,
                                                    const char* key) {
  std::vector<KotvWinChrome::LineItem> out;
  const auto it = m.find(flutter::EncodableValue(key));
  if (it == m.end() || !std::holds_alternative<flutter::EncodableList>(it->second)) return out;
  for (const auto& v : std::get<flutter::EncodableList>(it->second)) {
    if (!std::holds_alternative<flutter::EncodableMap>(v)) continue;
    const auto& row = std::get<flutter::EncodableMap>(v);
    KotvWinChrome::LineItem item;
    item.id = GetString(row, "id");
    item.label = Utf8ToWide(GetString(row, "label"));
    item.trailing = Utf8ToWide(GetString(row, "trailing"));
    item.toggle = GetBool(row, "toggle");
    item.on = GetBool(row, "on");
    item.chevron = GetBool(row, "chevron", !GetBool(row, "toggle") && !GetBool(row, "slider"));
    item.slider = GetBool(row, "slider");
    item.slider_min = GetDouble(row, "min", 0);
    item.slider_max = GetDouble(row, "max", 100);
    item.slider_value = GetDouble(row, "value", item.slider_min);
    if (item.id.empty() && !item.label.empty()) {
      item.id = GetString(row, "label");
    }
    out.push_back(std::move(item));
  }
  return out;
}

void FillRectColor(HDC hdc, const RECT& rc, COLORREF c) {
  HBRUSH br = CreateSolidBrush(c);
  FillRect(hdc, &rc, br);
  DeleteObject(br);
}

void FillRoundRect(HDC hdc, const RECT& rc, int radius, COLORREF fill, COLORREF border = 0,
                   int border_w = 0) {
  HBRUSH br = CreateSolidBrush(fill);
  HPEN pen = border_w > 0 ? CreatePen(PS_SOLID, border_w, border) : CreatePen(PS_NULL, 0, 0);
  HGDIOBJ old_br = SelectObject(hdc, br);
  HGDIOBJ old_pen = SelectObject(hdc, pen);
  RoundRect(hdc, rc.left, rc.top, rc.right, rc.bottom, radius * 2, radius * 2);
  SelectObject(hdc, old_br);
  SelectObject(hdc, old_pen);
  DeleteObject(br);
  DeleteObject(pen);
}

void DrawTextLine(HDC hdc, const RECT& rc, const std::wstring& text, COLORREF color, int px,
                  bool bold = false, UINT align = DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS) {
  HFONT font = CreateFontW(-px, 0, 0, 0, bold ? FW_SEMIBOLD : FW_NORMAL, FALSE, FALSE, FALSE,
                           DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY,
                           DEFAULT_PITCH | FF_SWISS, L"Segoe UI");
  HGDIOBJ old = SelectObject(hdc, font);
  SetBkMode(hdc, TRANSPARENT);
  SetTextColor(hdc, color);
  RECT r = rc;
  DrawTextW(hdc, text.c_str(), -1, &r, align);
  SelectObject(hdc, old);
  DeleteObject(font);
}

COLORREF Blend(COLORREF a, COLORREF b, double t) {
  auto ch = [&](int shift) {
    const int ca = (a >> shift) & 0xFF;
    const int cb = (b >> shift) & 0xFF;
    return static_cast<int>(ca + (cb - ca) * t);
  };
  return RGB(ch(0), ch(8), ch(16));
}

}  // namespace

KotvWinChrome::KotvWinChrome(flutter::PluginRegistrarWindows* registrar) : registrar_(registrar) {}

KotvWinChrome::~KotvWinChrome() { DestroyAll(); }

void KotvWinChrome::SetEventSink(EventFn fn) { event_fn_ = std::move(fn); }

HWND KotvWinChrome::FlutterHwnd() const {
  return registrar_ ? registrar_->GetView()->GetNativeWindow() : nullptr;
}

HWND KotvWinChrome::RootHwnd() const {
  HWND flutter = FlutterHwnd();
  return flutter ? GetAncestor(flutter, GA_ROOT) : nullptr;
}

void KotvWinChrome::EnsureClasses() {
  if (classes_ready_) return;
  WNDCLASSW wc{};
  wc.lpfnWndProc = WndProc;
  wc.hInstance = GetModuleHandleW(nullptr);
  wc.lpszClassName = kClass;
  wc.hCursor = LoadCursor(nullptr, IDC_ARROW);
  wc.hbrBackground = reinterpret_cast<HBRUSH>(GetStockObject(BLACK_BRUSH));
  RegisterClassW(&wc);

  WNDCLASSW dc{};
  dc.lpfnWndProc = DanmakuWndProc;
  dc.hInstance = GetModuleHandleW(nullptr);
  dc.lpszClassName = kDanmakuClass;
  dc.hCursor = LoadCursor(nullptr, IDC_ARROW);
  dc.hbrBackground = CreateSolidBrush(kDanmakuKey);
  RegisterClassW(&dc);

  WNDCLASSW mc{};
  mc.lpfnWndProc = ModalWndProc;
  mc.hInstance = GetModuleHandleW(nullptr);
  mc.lpszClassName = kModalClass;
  mc.hCursor = LoadCursor(nullptr, IDC_ARROW);
  mc.hbrBackground = reinterpret_cast<HBRUSH>(GetStockObject(NULL_BRUSH));
  RegisterClassW(&mc);
  classes_ready_ = true;
}

HWND KotvWinChrome::CreateChildPanel(const wchar_t* title) {
  HWND parent = FlutterHwnd();
  if (!parent) return nullptr;
  HWND hwnd = CreateWindowExW(WS_EX_NOACTIVATE, kClass, title,
                              WS_CHILD | WS_CLIPSIBLINGS, 0, 0, 0, 0, parent, nullptr,
                              GetModuleHandleW(nullptr), this);
  if (hwnd) SetWindowLongPtrW(hwnd, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(this));
  return hwnd;
}

HWND KotvWinChrome::CreateLayeredPopup(const wchar_t* class_name) {
  HWND owner = RootHwnd();
  if (!owner) return nullptr;
  HWND hwnd = CreateWindowExW(WS_EX_LAYERED | WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE,
                              class_name, L"", WS_POPUP, 0, 0, 0, 0, owner, nullptr,
                              GetModuleHandleW(nullptr), this);
  if (hwnd) {
    SetWindowLongPtrW(hwnd, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(this));
    SetLayeredWindowAttributes(hwnd, 0, 235, LWA_ALPHA);
  }
  return hwnd;
}

void KotvWinChrome::ApplyRoundRegion(HWND hwnd, int w, int h, int radius) {
  if (!hwnd || w <= 0 || h <= 0) return;
  HRGN rgn = CreateRoundRectRgn(0, 0, w + 1, h + 1, radius * 2, radius * 2);
  SetWindowRgn(hwnd, rgn, TRUE);
}

void KotvWinChrome::DestroyAll() {
  CloseSheet();
  if (danmaku_timer_ && danmaku_hwnd_) {
    KillTimer(danmaku_hwnd_, danmaku_timer_);
    danmaku_timer_ = 0;
  }
  auto destroy = [](HWND& h) {
    if (h) {
      DestroyWindow(h);
      h = nullptr;
    }
  };
  destroy(top_.hwnd);
  destroy(bottom_.hwnd);
  destroy(episodes_.hwnd);
  destroy(live_left_.hwnd);
  destroy(live_right_.hwnd);
  destroy(channel_info_.hwnd);
  destroy(center_play_.hwnd);
  destroy(danmaku_hwnd_);
  destroy(modal_hwnd_);
}

void KotvWinChrome::ShowPanel(Panel& p, bool show, int x, int y, int w, int h) {
  if (!p.hwnd) return;
  if (!show || w <= 0 || h <= 0) {
    ShowWindow(p.hwnd, SW_HIDE);
    return;
  }
  SetWindowPos(p.hwnd, HWND_TOP, x, y, w, h, SWP_SHOWWINDOW | SWP_NOACTIVATE);
  InvalidateRect(p.hwnd, nullptr, TRUE);
}

void KotvWinChrome::Layout() {
  HWND parent = FlutterHwnd();
  if (!parent || !enabled_) return;
  RECT rc{};
  GetClientRect(parent, &rc);
  const int W = rc.right - rc.left;
  const int H = rc.bottom - rc.top;

  if (!top_.hwnd) top_.hwnd = CreateChildPanel(L"kotv_top");
  if (!bottom_.hwnd) bottom_.hwnd = CreateChildPanel(L"kotv_bottom");
  if (!episodes_.hwnd) episodes_.hwnd = CreateChildPanel(L"kotv_ep");
  if (!live_left_.hwnd) live_left_.hwnd = CreateChildPanel(L"kotv_live_l");
  if (!live_right_.hwnd) live_right_.hwnd = CreateChildPanel(L"kotv_live_r");
  if (!channel_info_.hwnd) channel_info_.hwnd = CreateChildPanel(L"kotv_ch");
  if (!center_play_.hwnd) center_play_.hwnd = CreateChildPanel(L"kotv_center");
  if (!danmaku_hwnd_) {
    danmaku_hwnd_ = CreateWindowExW(
        WS_EX_LAYERED | WS_EX_TRANSPARENT | WS_EX_NOACTIVATE, kDanmakuClass, L"",
        WS_CHILD | WS_CLIPSIBLINGS, 0, 0, 0, 0, parent, nullptr, GetModuleHandleW(nullptr), this);
    if (danmaku_hwnd_) {
      SetWindowLongPtrW(danmaku_hwnd_, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(this));
      SetLayeredWindowAttributes(danmaku_hwnd_, kDanmakuKey, 0, LWA_COLORKEY);
      danmaku_timer_ = SetTimer(danmaku_hwnd_, 1, 33, nullptr);
    }
  }

  const bool inline_mode = mode_ == "vod_inline";
  if (inline_mode) {
    // 详情非全屏：底栏锚在视频卡片控件区（屏幕坐标 → Flutter 客户区）
    int ax = 0, ay = 0, aw = 0, ah = 0;
    const bool ok = bottom_visible_ && ResolveAnchor(&ax, &ay, &aw, &ah);
    ShowPanel(top_, false, 0, 0, 0, 0);
    ShowPanel(episodes_, false, 0, 0, 0, 0);
    ShowPanel(live_left_, false, 0, 0, 0, 0);
    ShowPanel(live_right_, false, 0, 0, 0, 0);
    ShowPanel(channel_info_, false, 0, 0, 0, 0);
    ShowPanel(center_play_, false, 0, 0, 0, 0);
    ShowPanel(bottom_, ok, ax, ay, aw, ah > 0 ? ah : kInlineBottomH);
  } else {
    ShowPanel(top_, top_visible_, 0, 0, W, kTopH);
    ShowPanel(bottom_, bottom_visible_, 0, H - kBottomH, W, kBottomH);
    ShowPanel(episodes_, episodes_visible_, W - kEpW, kTopH, kEpW, H - kTopH - kBottomH);
    const int live_top = kTopH + 8;
    const int live_h =
        H - live_top - (channel_visible_ ? kChannelH + 12 : 12) - (bottom_visible_ ? kBottomH : 0);
    ShowPanel(live_left_, live_left_visible_, 12, live_top, kLiveLeftW, std::max(120, live_h));
    ShowPanel(live_right_, live_right_visible_, W - kLiveRightW - 12, live_top, kLiveRightW,
              std::max(120, live_h));
    ShowPanel(channel_info_, channel_visible_, 24, H - kBottomH - kChannelH - 10, W - 48, kChannelH);
    ShowPanel(center_play_, center_visible_, (W - kCenterSz) / 2, (H - kCenterSz) / 2, kCenterSz,
              kCenterSz);
  }
  LayoutDanmaku();
  LayoutModal();
}

bool KotvWinChrome::ResolveAnchor(int* x, int* y, int* w, int* h) const {
  if (!anchor_valid_ || anchor_screen_w_ < 8 || anchor_screen_h_ < 8) return false;
  HWND parent = FlutterHwnd();
  if (!parent) return false;
  POINT tl{static_cast<LONG>(std::lround(anchor_screen_l_)),
           static_cast<LONG>(std::lround(anchor_screen_t_))};
  if (!ScreenToClient(parent, &tl)) return false;
  *x = tl.x;
  *y = tl.y;
  *w = static_cast<int>(std::lround(anchor_screen_w_));
  *h = static_cast<int>(std::lround(anchor_screen_h_));
  return *w >= 8 && *h >= 8;
}

void KotvWinChrome::LayoutDanmaku() {
  HWND parent = FlutterHwnd();
  if (!parent || !danmaku_hwnd_) return;
  RECT rc{};
  GetClientRect(parent, &rc);
  const int W = rc.right - rc.left;
  const int H = rc.bottom - rc.top;
  if (!danmaku_enabled_ || W <= 0 || H <= 0) {
    ShowWindow(danmaku_hwnd_, SW_HIDE);
    return;
  }
  SetWindowPos(danmaku_hwnd_, HWND_TOP, 0, 0, W, H, SWP_SHOWWINDOW | SWP_NOACTIVATE);
  if (top_.hwnd && top_visible_) SetWindowPos(top_.hwnd, HWND_TOP, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
  if (bottom_.hwnd && bottom_visible_)
    SetWindowPos(bottom_.hwnd, HWND_TOP, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
  if (live_left_.hwnd && live_left_visible_)
    SetWindowPos(live_left_.hwnd, HWND_TOP, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
  if (live_right_.hwnd && live_right_visible_)
    SetWindowPos(live_right_.hwnd, HWND_TOP, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
  if (episodes_.hwnd && episodes_visible_)
    SetWindowPos(episodes_.hwnd, HWND_TOP, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
  if (channel_info_.hwnd && channel_visible_)
    SetWindowPos(channel_info_.hwnd, HWND_TOP, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
  if (center_play_.hwnd && center_visible_)
    SetWindowPos(center_play_.hwnd, HWND_TOP, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
}

void KotvWinChrome::LayoutModal() {
  if (sheet_kind_.empty()) {
    if (modal_hwnd_) ShowWindow(modal_hwnd_, SW_HIDE);
    return;
  }
  HWND parent = FlutterHwnd();
  HWND root = RootHwnd();
  if (!parent || !root) return;
  if (!modal_hwnd_) modal_hwnd_ = CreateLayeredPopup(kModalClass);
  if (!modal_hwnd_) return;

  RECT prc{}, rrc{};
  GetClientRect(parent, &prc);
  GetWindowRect(root, &rrc);
  POINT origin{0, 0};
  ClientToScreen(parent, &origin);

  const bool light = sheet_kind_ == "danmaku" || sheet_kind_ == "volume";
  const int rows = static_cast<int>(sheet_items_.size());
  const int row_h = light ? 56 : 48;
  const int header = light ? 52 : (sheet_subtitle_.empty() ? 40 : 54);
  const int h = std::min(kModalMaxH, header + rows * row_h + 24);
  const int w = light ? 380 : kModalW;
  const int x = origin.x + (prc.right - w) / 2;
  const int y = origin.y + (prc.bottom - h) / 2;
  SetLayeredWindowAttributes(modal_hwnd_, 0, light ? 245 : 230, LWA_ALPHA);
  SetWindowPos(modal_hwnd_, HWND_TOPMOST, x, y, w, h, SWP_SHOWWINDOW | SWP_NOACTIVATE);
  ApplyRoundRegion(modal_hwnd_, w, h, 16);
  InvalidateRect(modal_hwnd_, nullptr, TRUE);
}

void KotvWinChrome::CloseSheet() {
  sheet_kind_.clear();
  sheet_items_.clear();
  sheet_title_.clear();
  sheet_subtitle_.clear();
  if (modal_hwnd_) ShowWindow(modal_hwnd_, SW_HIDE);
}

void KotvWinChrome::Emit(EncodableMap map) {
  if (event_fn_) event_fn_(std::move(map));
}

void KotvWinChrome::PaintTop(HDC hdc, const RECT& rc) {
  FillRectColor(hdc, rc, kBarDark);
  RECT accent{rc.left, rc.top, rc.left + 4, rc.bottom};
  FillRectColor(hdc, accent, kPink);

  RECT title_rc{rc.left + 18, rc.top + 8, rc.right - 100, rc.top + 32};
  DrawTextLine(hdc, title_rc, title_.empty() ? L"播放中" : title_, RGB(255, 255, 255), 16, true);
  if (!subtitle_.empty()) {
    RECT sub{rc.left + 18, rc.top + 30, rc.right - 100, rc.bottom - 6};
    DrawTextLine(hdc, sub, subtitle_, RGB(170, 170, 180), 12, false);
  }

  RECT exit_rc{rc.right - 88, rc.top + 12, rc.right - 16, rc.bottom - 12};
  FillRoundRect(hdc, exit_rc, 8, RGB(40, 32, 48), RGB(80, 70, 90), 1);
  DrawTextLine(hdc, exit_rc, L"退出", RGB(240, 240, 245), 13, true, DT_CENTER | DT_VCENTER | DT_SINGLELINE);
}

void KotvWinChrome::PaintBottom(HDC hdc, const RECT& rc) {
  if (mode_ == "vod_inline") {
    PaintBottomInline(hdc, rc);
  } else {
    PaintBottomFullscreen(hdc, rc);
  }
}

void KotvWinChrome::PaintBottomInline(HDC hdc, const RECT& rc) {
  // 对齐 VodInlineControls：半透明底 + 动作行 + 进度
  FillRectColor(hdc, rc, RGB(10, 10, 18));
  const int W = rc.right - rc.left;
  const int icon = 34;
  const int ay = rc.top + 4;
  int ax = rc.left + 6;
  auto paint_icon = [&](const std::wstring& glyph, bool accent = false) {
    RECT ir{ax, ay, ax + icon, ay + icon};
    if (accent) FillRoundRect(hdc, ir, 8, RGB(50, 28, 36));
    DrawTextLine(hdc, ir, glyph, accent ? kPink : RGB(235, 235, 240), 15, true,
                 DT_CENTER | DT_VCENTER | DT_SINGLELINE);
    ax += icon + 4;
  };
  paint_icon(playing_ ? L"❚❚" : L"▶", true);
  paint_icon(L"■");
  if (show_direct_) paint_icon(direct_on_ ? L"D●" : L"D○");
  paint_icon(L"📺");  // 投屏
  paint_icon(mini_active_ ? L"▣" : L"⧉");
  paint_icon(L"⛶");  // 全屏

  std::wstring time = (pos_label_.empty() ? L"0:00" : pos_label_) + L" / " +
                      (dur_label_.empty() ? L"0:00" : dur_label_);
  RECT time_rc{ax + 4, ay, rc.right - 90, ay + icon};
  DrawTextLine(hdc, time_rc, time, RGB(200, 200, 210), 11);

  RECT vol_rc{rc.right - 84, ay + 4, rc.right - 8, ay + icon - 4};
  FillRoundRect(hdc, vol_rc, 8, RGB(40, 36, 48));
  const std::wstring vol_l = L"♪ " + Utf8ToWide(std::to_string(static_cast<int>(std::lround(volume_))));
  DrawTextLine(hdc, vol_rc, vol_l, RGB(230, 230, 235), 11, false,
               DT_CENTER | DT_VCENTER | DT_SINGLELINE);

  const int track_y = rc.bottom - 18;
  RECT track{rc.left + 10, track_y, rc.right - 10, track_y + 4};
  FillRoundRect(hdc, track, 2, RGB(55, 48, 62));
  const int filled = static_cast<int>((W - 20) * std::clamp(progress_, 0.0, 1.0));
  if (filled > 0) {
    RECT prog{track.left, track.top, track.left + filled, track.bottom};
    FillRoundRect(hdc, prog, 2, kPink);
  }
  if (buffering_) {
    RECT b{rc.left + W / 2 - 36, rc.top + 2, rc.left + W / 2 + 36, rc.top + 16};
    DrawTextLine(hdc, b, L"加载中…", RGB(220, 180, 190), 10, false,
                 DT_CENTER | DT_VCENTER | DT_SINGLELINE);
  }
}

void KotvWinChrome::PaintBottomFullscreen(HDC hdc, const RECT& rc) {
  FillRectColor(hdc, rc, kBarDark);
  const int W = rc.right - rc.left;
  const int track_y = rc.top + 14;
  const int track_h = 4;
  RECT track{rc.left + 16, track_y, rc.right - 16, track_y + track_h};
  FillRoundRect(hdc, track, 2, RGB(55, 48, 62));
  const int filled = static_cast<int>((W - 32) * std::clamp(progress_, 0.0, 1.0));
  if (filled > 0) {
    RECT prog{track.left, track.top, track.left + filled, track.bottom};
    FillRoundRect(hdc, prog, 2, kPink);
    const int knob = track.left + filled;
    Ellipse(hdc, knob - 6, track_y - 4, knob + 6, track_y + track_h + 4);
  }

  RECT tL{rc.left + 16, track_y + 10, rc.left + 90, track_y + 28};
  RECT tR{rc.right - 90, track_y + 10, rc.right - 16, track_y + 28};
  DrawTextLine(hdc, tL, pos_label_.empty() ? L"0:00" : pos_label_, RGB(200, 200, 210), 11);
  DrawTextLine(hdc, tR, dur_label_.empty() ? L"0:00" : dur_label_, RGB(200, 200, 210), 11,
               false, DT_RIGHT | DT_VCENTER | DT_SINGLELINE);

  const int ay = rc.top + 44;
  const int icon = 36;
  int ax = rc.left + 20;
  auto paint_icon = [&](const std::wstring& glyph, bool accent = false) {
    RECT ir{ax, ay, ax + icon, ay + icon};
    if (accent) FillRoundRect(hdc, ir, 8, RGB(50, 28, 36));
    DrawTextLine(hdc, ir, glyph, accent ? kPink : RGB(235, 235, 240), 16, true,
                 DT_CENTER | DT_VCENTER | DT_SINGLELINE);
    ax += icon + 10;
  };
  paint_icon(L"⏮");
  paint_icon(playing_ ? L"❚❚" : L"▶", true);
  paint_icon(L"⏭");
  paint_icon(L"≡");

  RECT clock_rc{rc.right - 150, ay - 4, rc.right - 16, ay + 22};
  DrawTextLine(hdc, clock_rc, clock_.empty() ? L"--:--" : clock_, RGB(255, 255, 255), 22, true,
               DT_RIGHT | DT_VCENTER | DT_SINGLELINE);
  if (!ends_at_.empty()) {
    RECT ends{rc.right - 150, ay + 20, rc.right - 16, ay + 38};
    DrawTextLine(hdc, ends, ends_at_, RGB(160, 160, 170), 11, false,
                 DT_RIGHT | DT_VCENTER | DT_SINGLELINE);
  }

  if (buffering_) {
    RECT b{rc.left + W / 2 - 40, rc.top + 4, rc.left + W / 2 + 40, rc.top + 22};
    DrawTextLine(hdc, b, L"加载中…", RGB(220, 180, 190), 11, false,
                 DT_CENTER | DT_VCENTER | DT_SINGLELINE);
  }
}

void KotvWinChrome::PaintEpisodes(HDC hdc, const RECT& rc) {
  FillRectColor(hdc, rc, Blend(kPanelDark, RGB(0, 0, 0), 0.15));
  RECT head{rc.left + 12, rc.top + 10, rc.right - 12, rc.top + 36};
  DrawTextLine(hdc, head, L"选集", RGB(255, 255, 255), 15, true);
  const int row_h = 40;
  for (size_t i = 0; i < episode_lines_.size(); ++i) {
    const int y = rc.top + 44 + static_cast<int>(i) * row_h;
    if (y + row_h > rc.bottom) break;
    RECT row{rc.left + 8, y, rc.right - 8, y + row_h - 4};
    if (static_cast<int>(i) == episode_selected_) {
      FillRoundRect(hdc, row, 8, Blend(kPink, kPanelDark, 0.55));
    }
    DrawTextLine(hdc, row, episode_lines_[i],
                 static_cast<int>(i) == episode_selected_ ? RGB(255, 220, 225) : RGB(210, 210, 220), 13);
  }
}

void KotvWinChrome::PaintLiveLeft(HDC hdc, const RECT& rc) {
  FillRoundRect(hdc, rc, 12, Blend(kPanelDark, RGB(0, 0, 0), 0.1));
  const int W = rc.right - rc.left;
  const int H = rc.bottom - rc.top;

  if (groups_.empty()) {
    RECT head{rc.left + 12, rc.top + 10, rc.right - 12, rc.top + 36};
    DrawTextLine(hdc, head, L"频道", RGB(255, 255, 255), 15, true);
    for (size_t i = 0; i < channels_.size(); ++i) {
      const int y = rc.top + 44 + static_cast<int>(i) * 36;
      if (y + 32 > rc.bottom - 36) break;
      RECT row{rc.left + 8, y, rc.right - 8, y + 32};
      if (static_cast<int>(i) == channel_selected_) {
        FillRoundRect(hdc, row, 8, Blend(kPink, kPanelDark, 0.55));
      }
      DrawTextLine(hdc, row, channels_[i],
                   static_cast<int>(i) == channel_selected_ ? RGB(255, 230, 235) : RGB(210, 210, 220),
                   12);
    }
    RECT collapse{rc.left + 8, rc.bottom - 32, rc.right - 8, rc.bottom - 8};
    FillRoundRect(hdc, collapse, 8, Blend(kPink, kPanelDark, 0.35));
    DrawTextLine(hdc, collapse, L"收起", RGB(255, 230, 235), 12, true,
                 DT_CENTER | DT_VCENTER | DT_SINGLELINE);
    (void)W;
    (void)H;
    return;
  }

  const int gW = 72;
  const int cW = 150;
  const int eW = W - gW - cW - 8;

  // 分组列
  RECT gcol{rc.left, rc.top, rc.left + gW, rc.bottom};
  FillRectColor(hdc, gcol, RGB(22, 14, 30));
  for (size_t i = 0; i < groups_.size(); ++i) {
    const int y = rc.top + 8 + static_cast<int>(i) * 40;
    if (y + 36 > rc.bottom - 36) break;
    RECT row{rc.left + 4, y, rc.left + gW - 4, y + 36};
    if (static_cast<int>(i) == group_selected_) {
      FillRoundRect(hdc, row, 8, Blend(kPink, kPanelDark, 0.5));
    }
    DrawTextLine(hdc, row, groups_[i],
                 static_cast<int>(i) == group_selected_ ? RGB(255, 230, 235) : RGB(180, 180, 190), 12,
                 static_cast<int>(i) == group_selected_, DT_CENTER | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS);
  }

  // 频道列
  for (size_t i = 0; i < channels_.size(); ++i) {
    const int y = rc.top + 8 + static_cast<int>(i) * 36;
    if (y + 32 > rc.bottom - 36) break;
    RECT row{rc.left + gW + 4, y, rc.left + gW + cW - 4, y + 32};
    if (static_cast<int>(i) == channel_selected_) {
      FillRoundRect(hdc, row, 6, Blend(kPink, kPanelDark, 0.6));
    }
    DrawTextLine(hdc, row, channels_[i],
                 static_cast<int>(i) == channel_selected_ ? RGB(255, 235, 238) : RGB(205, 205, 215), 12);
  }

  // EPG 列
  RECT ecol{rc.left + gW + cW, rc.top, rc.right - 4, rc.bottom - 36};
  // day tabs
  int tx = ecol.left + 4;
    for (size_t i = 0; i < epg_days_.size() && i < 14; ++i) {
    RECT tab{tx, ecol.top + 6, tx + 52, ecol.top + 30};
    if (static_cast<int>(i) == epg_day_selected_) {
      FillRoundRect(hdc, tab, 6, Blend(kPink, kPanelDark, 0.45));
    }
    DrawTextLine(hdc, tab, epg_days_[i],
                 static_cast<int>(i) == epg_day_selected_ ? RGB(255, 255, 255) : RGB(170, 170, 180), 11,
                 false, DT_CENTER | DT_VCENTER | DT_SINGLELINE);
    tx += 56;
  }
  for (size_t i = 0; i < epg_programs_.size(); ++i) {
    const int y = ecol.top + 38 + static_cast<int>(i) * 32;
    if (y + 28 > ecol.bottom) break;
    RECT row{ecol.left + 4, y, ecol.right - 4, y + 28};
    if (static_cast<int>(i) == epg_program_selected_) {
      FillRoundRect(hdc, row, 6, Blend(kPinkMuted, kPanelDark, 0.4));
    }
    DrawTextLine(hdc, row, epg_programs_[i], RGB(210, 210, 220), 11);
  }

  // 收起条
  RECT collapse{rc.left + 8, rc.bottom - 32, rc.right - 8, rc.bottom - 8};
  FillRoundRect(hdc, collapse, 8, Blend(kPink, kPanelDark, 0.35));
  DrawTextLine(hdc, collapse, L"收起", RGB(255, 230, 235), 12, true,
               DT_CENTER | DT_VCENTER | DT_SINGLELINE);
  (void)eW;
  (void)H;
}

void KotvWinChrome::PaintLiveRight(HDC hdc, const RECT& rc) {
  FillRoundRect(hdc, rc, 12, Blend(kPanelDark, RGB(0, 0, 0), 0.12));
  RECT head{rc.left + 14, rc.top + 12, rc.right - 14, rc.top + 36};
  DrawTextLine(hdc, head, L"直播设置", RGB(255, 255, 255), 14, true);

  const int start = rc.top + 48;
  const int gap = 10;
  const int pill_h = 40;
  for (size_t i = 0; i < live_right_items_.size(); ++i) {
    const int y = start + static_cast<int>(i) * (pill_h + gap);
    if (y + pill_h > rc.bottom - 12) break;
    RECT pill{rc.left + 12, y, rc.right - 12, y + pill_h};
    const bool focus = static_cast<int>(i) == 0;
    FillRoundRect(hdc, pill, 20, RGB(255, 255, 255), focus ? kPink : RGB(220, 220, 225), focus ? 2 : 1);
    std::wstring label = live_right_items_[i].label;
    if (!live_right_items_[i].trailing.empty()) {
      label += L"  ";
      label += live_right_items_[i].trailing;
    }
    DrawTextLine(hdc, pill, label, RGB(40, 40, 48), 12, true,
                 DT_CENTER | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS);
  }
}

void KotvWinChrome::PaintChannelInfo(HDC hdc, const RECT& rc) {
  // 浅半透明白底条
  FillRoundRect(hdc, rc, 10, RGB(245, 245, 248), RGB(220, 220, 228), 1);
  RECT no{rc.left + 12, rc.top + 8, rc.left + 48, rc.bottom - 8};
  DrawTextLine(hdc, no, channel_no_.empty() ? L"-" : channel_no_, RGB(60, 60, 70), 18, true,
               DT_CENTER | DT_VCENTER | DT_SINGLELINE);
  RECT name{rc.left + 52, rc.top + 6, rc.left + 200, rc.top + 24};
  DrawTextLine(hdc, name, channel_name_, RGB(30, 30, 36), 13, true);
  RECT prog{rc.left + 52, rc.top + 24, rc.right - 16, rc.bottom - 6};
  const std::wstring prog_text =
      channel_ticker_.empty()
          ? channel_prog_
          : (channel_prog_.empty() ? channel_ticker_ : channel_prog_ + L"  ·  " + channel_ticker_);
  DrawTextLine(hdc, prog, prog_text, kPink, 12, false);
}

void KotvWinChrome::PaintCenter(HDC hdc, const RECT& rc) {
  FillRoundRect(hdc, rc, 36, Blend(kPanelDark, RGB(0, 0, 0), 0.2), RGB(90, 80, 100), 1);
  DrawTextLine(hdc, rc, playing_ ? L"❚❚" : L"▶", RGB(255, 255, 255), 22, true,
               DT_CENTER | DT_VCENTER | DT_SINGLELINE);
}

void KotvWinChrome::PaintModal(HDC hdc, const RECT& rc) {
  const bool light = sheet_kind_ == "danmaku" || sheet_kind_ == "volume";
  FillRoundRect(hdc, rc, 16, light ? kSheetLight : Blend(kPanelDark, RGB(0, 0, 0), 0.05));

  if (light) {
    RECT title{rc.left + 16, rc.top + 12, rc.right - 48, rc.top + 40};
    DrawTextLine(hdc, title,
                 sheet_title_.empty() ? (sheet_kind_ == "volume" ? L"音量" : L"弹幕设置") : sheet_title_,
                 RGB(30, 30, 36), 16, true);
    RECT close{rc.right - 40, rc.top + 10, rc.right - 12, rc.top + 38};
    DrawTextLine(hdc, close, L"✕", RGB(90, 90, 100), 16, true, DT_CENTER | DT_VCENTER | DT_SINGLELINE);

    for (size_t i = 0; i < sheet_items_.size(); ++i) {
      const auto& it = sheet_items_[i];
      const int y = rc.top + 52 + static_cast<int>(i) * 56;
      RECT row{rc.left + 16, y, rc.right - 16, y + 48};
      DrawTextLine(hdc, row, it.label, RGB(40, 40, 48), 13, false,
                   DT_LEFT | DT_TOP | DT_SINGLELINE);
      if (it.toggle) {
        RECT sw{rc.right - 70, y + 12, rc.right - 24, y + 36};
        FillRoundRect(hdc, sw, 12, it.on ? kGreenOn : RGB(200, 200, 208));
        const int knob_x = it.on ? sw.right - 22 : sw.left + 2;
        HBRUSH white = CreateSolidBrush(RGB(255, 255, 255));
        HGDIOBJ old = SelectObject(hdc, white);
        HPEN pen = CreatePen(PS_NULL, 0, 0);
        HGDIOBJ oldp = SelectObject(hdc, pen);
        Ellipse(hdc, knob_x, sw.top + 2, knob_x + 20, sw.bottom - 2);
        SelectObject(hdc, old);
        SelectObject(hdc, oldp);
        DeleteObject(white);
        DeleteObject(pen);
      } else if (it.slider) {
        const double span = std::max(1e-6, it.slider_max - it.slider_min);
        const double t = std::clamp((it.slider_value - it.slider_min) / span, 0.0, 1.0);
        RECT tr{rc.right - 72, y, rc.right - 16, y + 22};
        DrawTextLine(hdc, tr, it.trailing.empty() ? Utf8ToWide(std::to_string(static_cast<int>(std::lround(it.slider_value)))) : it.trailing,
                     RGB(100, 100, 110), 12, false, DT_RIGHT | DT_VCENTER | DT_SINGLELINE);
        RECT track{rc.left + 16, y + 30, rc.right - 16, y + 36};
        FillRoundRect(hdc, track, 2, RGB(210, 210, 218));
        const int filled = static_cast<int>((track.right - track.left) * t);
        RECT prog{track.left, track.top, track.left + filled, track.bottom};
        FillRoundRect(hdc, prog, 2, kPink);
        const int knob = track.left + filled;
        Ellipse(hdc, knob - 6, track.top - 4, knob + 6, track.bottom + 4);
      } else if (!it.trailing.empty() || it.chevron) {
        RECT trail{rc.right - 100, y, rc.right - 16, y + 44};
        DrawTextLine(hdc, trail, it.trailing.empty() ? L"›" : it.trailing, RGB(100, 100, 110), 12, false,
                     DT_RIGHT | DT_VCENTER | DT_SINGLELINE);
      }
    }
    return;
  }

  // 暗色更多 / 选播放器
  if (!sheet_title_.empty()) {
    RECT title{rc.left + 16, rc.top + 10, rc.right - 16, rc.top + 34};
    DrawTextLine(hdc, title, sheet_title_, RGB(255, 255, 255), 14, true);
  }
  if (!sheet_subtitle_.empty()) {
    RECT sub{rc.left + 16, rc.top + 32, rc.right - 16, rc.top + 50};
    DrawTextLine(hdc, sub, sheet_subtitle_, RGB(170, 170, 180), 11);
  }
  const int header = sheet_subtitle_.empty() ? 40 : 54;
  for (size_t i = 0; i < sheet_items_.size(); ++i) {
    const auto& it = sheet_items_[i];
    const int y = rc.top + header + static_cast<int>(i) * 48;
    RECT row{rc.left + 10, y, rc.right - 10, y + 44};
    const bool sel = static_cast<int>(i) == sheet_selected_ ||
                     (sheet_kind_ == "player" && static_cast<int>(i) == sheet_selected_);
    if (sel && sheet_kind_ == "player") {
      FillRoundRect(hdc, row, 10, Blend(kPink, kPanelDark, 0.45));
    } else if (static_cast<int>(i) == sheet_selected_ && sheet_kind_ == "more") {
      FillRoundRect(hdc, row, 10, RGB(40, 28, 48));
    }
    DrawTextLine(hdc, row, it.label, RGB(240, 240, 245), 13, false,
                 DT_LEFT | DT_VCENTER | DT_SINGLELINE);
    RECT trail{rc.right - 90, y, rc.right - 16, y + 44};
    if (it.toggle) {
      RECT sw{rc.right - 70, y + 10, rc.right - 18, y + 34};
      FillRoundRect(hdc, sw, 12, it.on ? kPink : RGB(70, 60, 80));
      const int knob_x = it.on ? sw.right - 22 : sw.left + 2;
      HBRUSH white = CreateSolidBrush(RGB(255, 255, 255));
      HGDIOBJ old = SelectObject(hdc, white);
      HPEN pen = CreatePen(PS_NULL, 0, 0);
      HGDIOBJ oldp = SelectObject(hdc, pen);
      Ellipse(hdc, knob_x, sw.top + 2, knob_x + 20, sw.bottom - 2);
      SelectObject(hdc, old);
      SelectObject(hdc, oldp);
      DeleteObject(white);
      DeleteObject(pen);
    } else if (!it.trailing.empty()) {
      DrawTextLine(hdc, trail, it.trailing, RGB(180, 180, 190), 11, false,
                   DT_RIGHT | DT_VCENTER | DT_SINGLELINE);
    } else if (it.chevron) {
      DrawTextLine(hdc, trail, L"›", RGB(160, 160, 170), 18, false,
                   DT_RIGHT | DT_VCENTER | DT_SINGLELINE);
    }
    if (sheet_kind_ == "player" && static_cast<int>(i) == sheet_selected_) {
      DrawTextLine(hdc, trail, L"✓", kPink, 14, true, DT_RIGHT | DT_VCENTER | DT_SINGLELINE);
    }
  }
}

void KotvWinChrome::PaintPanel(HWND hwnd, HDC hdc, const RECT& rc) {
  if (hwnd == top_.hwnd) PaintTop(hdc, rc);
  else if (hwnd == bottom_.hwnd) PaintBottom(hdc, rc);
  else if (hwnd == episodes_.hwnd) PaintEpisodes(hdc, rc);
  else if (hwnd == live_left_.hwnd) PaintLiveLeft(hdc, rc);
  else if (hwnd == live_right_.hwnd) PaintLiveRight(hdc, rc);
  else if (hwnd == channel_info_.hwnd) PaintChannelInfo(hdc, rc);
  else if (hwnd == center_play_.hwnd) PaintCenter(hdc, rc);
}

void KotvWinChrome::PaintDanmaku(HWND hwnd) {
  RECT rc{};
  GetClientRect(hwnd, &rc);
  const int W = rc.right - rc.left;
  const int H = rc.bottom - rc.top;
  if (W <= 0 || H <= 0) return;

  HDC hdc = GetDC(hwnd);
  HDC mem = CreateCompatibleDC(hdc);
  HBITMAP bmp = CreateCompatibleBitmap(hdc, W, H);
  HGDIOBJ old = SelectObject(mem, bmp);
  FillRectColor(mem, rc, kDanmakuKey);

  if (danmaku_enabled_ && !danmaku_items_.empty()) {
    const int row_h = std::max(18, static_cast<int>(danmaku_font_ + 8));
    const int rows = std::max(1, danmaku_rows_);
    HFONT font = CreateFontW(-static_cast<int>(danmaku_font_), 0, 0, 0, FW_NORMAL, FALSE, FALSE,
                             FALSE, DEFAULT_CHARSET, OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS,
                             CLEARTYPE_QUALITY, DEFAULT_PITCH | FF_SWISS, L"Microsoft YaHei UI");
    HGDIOBJ oldf = SelectObject(mem, font);
    SetBkMode(mem, TRANSPARENT);

    for (size_t i = 0; i < danmaku_items_.size(); ++i) {
      const auto& d = danmaku_items_[i];
      const bool scroll = d.mode == 1 || d.mode == 6;
      const bool top = d.mode == 5;
      const bool bottom = d.mode == 4;
      if (scroll && !danmaku_show_scroll_) continue;
      if (top && !danmaku_show_top_) continue;
      if (bottom && !danmaku_show_bottom_) continue;
      if (d.mode == 6 && !danmaku_show_reverse_) continue;

      const double age = position_sec_ - d.time;
      if (age < -0.2) continue;
      const int dur = scroll ? danmaku_duration_ms_ : danmaku_fixed_ms_;
      if (age * 1000.0 > dur + 200) continue;

      const int row = static_cast<int>(i % rows);
      const int y = top ? 8 + row * row_h
                        : (bottom ? H - (rows - row) * row_h - 8 : 8 + row * row_h);
      SIZE sz{};
      GetTextExtentPoint32W(mem, d.content.c_str(), static_cast<int>(d.content.size()), &sz);
      int x = 0;
      if (scroll) {
        const double t = std::clamp(age * 1000.0 / dur, 0.0, 1.0);
        if (d.mode == 6) {
          x = static_cast<int>(-sz.cx + t * (W + sz.cx));
        } else {
          x = static_cast<int>(W - t * (W + sz.cx));
        }
      } else {
        x = (W - sz.cx) / 2;
      }
      const int r = (d.color >> 16) & 0xFF;
      const int g = (d.color >> 8) & 0xFF;
      const int b = d.color & 0xFF;
      SetTextColor(mem, RGB(r, g, b));
      TextOutW(mem, x, y, d.content.c_str(), static_cast<int>(d.content.size()));
    }
    SelectObject(mem, oldf);
    DeleteObject(font);
  }

  BitBlt(hdc, 0, 0, W, H, mem, 0, 0, SRCCOPY);
  SelectObject(mem, old);
  DeleteObject(bmp);
  DeleteDC(mem);
  ReleaseDC(hwnd, hdc);
}

LRESULT CALLBACK KotvWinChrome::WndProc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam) {
  if (msg == WM_NCCREATE) {
    auto* cs = reinterpret_cast<CREATESTRUCTW*>(lParam);
    SetWindowLongPtrW(hwnd, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(cs->lpCreateParams));
  }
  auto* self = reinterpret_cast<KotvWinChrome*>(GetWindowLongPtrW(hwnd, GWLP_USERDATA));
  if (self) return self->OnMessage(hwnd, msg, wParam, lParam);
  return DefWindowProcW(hwnd, msg, wParam, lParam);
}

LRESULT CALLBACK KotvWinChrome::DanmakuWndProc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam) {
  if (msg == WM_NCCREATE) {
    auto* cs = reinterpret_cast<CREATESTRUCTW*>(lParam);
    SetWindowLongPtrW(hwnd, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(cs->lpCreateParams));
  }
  auto* self = reinterpret_cast<KotvWinChrome*>(GetWindowLongPtrW(hwnd, GWLP_USERDATA));
  if (self) return self->OnDanmakuMessage(hwnd, msg, wParam, lParam);
  return DefWindowProcW(hwnd, msg, wParam, lParam);
}

LRESULT CALLBACK KotvWinChrome::ModalWndProc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam) {
  if (msg == WM_NCCREATE) {
    auto* cs = reinterpret_cast<CREATESTRUCTW*>(lParam);
    SetWindowLongPtrW(hwnd, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(cs->lpCreateParams));
  }
  auto* self = reinterpret_cast<KotvWinChrome*>(GetWindowLongPtrW(hwnd, GWLP_USERDATA));
  if (self) return self->OnModalMessage(hwnd, msg, wParam, lParam);
  return DefWindowProcW(hwnd, msg, wParam, lParam);
}

LRESULT KotvWinChrome::OnDanmakuMessage(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam) {
  switch (msg) {
    case WM_TIMER:
      PaintDanmaku(hwnd);
      return 0;
    case WM_PAINT: {
      PAINTSTRUCT ps;
      BeginPaint(hwnd, &ps);
      PaintDanmaku(hwnd);
      EndPaint(hwnd, &ps);
      return 0;
    }
    case WM_ERASEBKGND:
      return 1;
    default:
      return DefWindowProcW(hwnd, msg, wParam, lParam);
  }
}

LRESULT KotvWinChrome::OnModalMessage(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam) {
  switch (msg) {
    case WM_PAINT: {
      PAINTSTRUCT ps;
      HDC hdc = BeginPaint(hwnd, &ps);
      RECT rc{};
      GetClientRect(hwnd, &rc);
      PaintModal(hdc, rc);
      EndPaint(hwnd, &ps);
      return 0;
    }
    case WM_LBUTTONDOWN:
    case WM_LBUTTONUP: {
      const int x = LOWORD(lParam);
      const int y = HIWORD(lParam);
      RECT rc{};
      GetClientRect(hwnd, &rc);
      const bool light = sheet_kind_ == "danmaku" || sheet_kind_ == "volume";
      if (msg == WM_LBUTTONUP && light && x > rc.right - 48 && y < 48) {
        CloseSheet();
        Emit({{EncodableValue("type"), EncodableValue("sheetClose")},
              {EncodableValue("kind"), EncodableValue(sheet_kind_)}});
        return 0;
      }
      const int header = light ? 52 : (sheet_subtitle_.empty() ? 40 : 54);
      const int row_h = light ? 56 : 48;
      if (y < header) return 0;
      const int idx = (y - header) / row_h;
      if (idx < 0 || idx >= static_cast<int>(sheet_items_.size())) return 0;
      sheet_selected_ = idx;
      auto& it = sheet_items_[idx];
      if (it.slider) {
        const int track_l = rc.left + 16;
        const int track_r = rc.right - 16;
        const double t = std::clamp((x - track_l) / std::max(1.0, static_cast<double>(track_r - track_l)), 0.0, 1.0);
        it.slider_value = it.slider_min + t * (it.slider_max - it.slider_min);
        Emit({{EncodableValue("type"), EncodableValue("slider")},
              {EncodableValue("id"), EncodableValue(it.id)},
              {EncodableValue("value"), EncodableValue(it.slider_value)},
              {EncodableValue("commit"), EncodableValue(msg == WM_LBUTTONUP)},
              {EncodableValue("sheet"), EncodableValue(sheet_kind_)}});
        InvalidateRect(hwnd, nullptr, TRUE);
        return 0;
      }
      if (msg != WM_LBUTTONUP) return 0;
      if (it.toggle) {
        it.on = !it.on;
        Emit({{EncodableValue("type"), EncodableValue("toggleItem")},
              {EncodableValue("id"), EncodableValue(it.id)},
              {EncodableValue("on"), EncodableValue(it.on)},
              {EncodableValue("sheet"), EncodableValue(sheet_kind_)}});
        InvalidateRect(hwnd, nullptr, TRUE);
        return 0;
      }
      if (sheet_kind_ == "player") {
        Emit({{EncodableValue("type"), EncodableValue("pickPlayer")},
              {EncodableValue("id"), EncodableValue(it.id)}});
        CloseSheet();
        return 0;
      }
      // more 菜单用 type=more；子选择表（调色/倍速等）用 type=sheet
      if (sheet_kind_ == "more") {
        Emit({{EncodableValue("type"), EncodableValue("more")},
              {EncodableValue("id"), EncodableValue(it.id)},
              {EncodableValue("sheet"), EncodableValue(sheet_kind_)}});
      } else {
        Emit({{EncodableValue("type"), EncodableValue("sheet")},
              {EncodableValue("id"), EncodableValue(it.id)},
              {EncodableValue("kind"), EncodableValue(sheet_kind_)}});
      }
      CloseSheet();
      return 0;
    }
    case WM_ERASEBKGND:
      return 1;
    default:
      return DefWindowProcW(hwnd, msg, wParam, lParam);
  }
}

LRESULT KotvWinChrome::OnMessage(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam) {
  switch (msg) {
    case WM_PAINT: {
      PAINTSTRUCT ps;
      HDC hdc = BeginPaint(hwnd, &ps);
      RECT rc{};
      GetClientRect(hwnd, &rc);
      PaintPanel(hwnd, hdc, rc);
      EndPaint(hwnd, &ps);
      return 0;
    }
    case WM_LBUTTONUP: {
      const int x = LOWORD(lParam);
      const int y = HIWORD(lParam);
      RECT rc{};
      GetClientRect(hwnd, &rc);

      if (hwnd == top_.hwnd) {
        if (x > rc.right - 100) {
          Emit({{EncodableValue("type"), EncodableValue("exit")}});
        }
        return 0;
      }
      if (hwnd == bottom_.hwnd) {
        if (mode_ == "vod_inline") {
          // 下沿进度；上沿动作：play/stop/[direct]/cast/mini/expand | volume
          if (y > rc.bottom - 22) {
            const double p = std::clamp((x - 10.0) / std::max(1, rc.right - 20), 0.0, 1.0);
            Emit({{EncodableValue("type"), EncodableValue("seekFraction")},
                  {EncodableValue("value"), EncodableValue(p)}});
            return 0;
          }
          if (x > rc.right - 84) {
            Emit({{EncodableValue("type"), EncodableValue("volume")}});
            return 0;
          }
          const int slot = (x - 6) / 38;
          int i = 0;
          auto hit = [&](const char* type) {
            if (slot == i) {
              Emit({{EncodableValue("type"), EncodableValue(std::string(type))}});
            }
            ++i;
          };
          hit("toggle");
          hit("stop");
          if (show_direct_) hit("direct");
          hit("cast");
          hit("mini");
          hit("expand");
          return 0;
        }
        if (y < 36) {
          const double p = std::clamp((x - 16.0) / std::max(1, rc.right - 32), 0.0, 1.0);
          Emit({{EncodableValue("type"), EncodableValue("seekFraction")},
                {EncodableValue("value"), EncodableValue(p)}});
          return 0;
        }
        const int ay = 44;
        if (y >= ay && y <= ay + 36) {
          const int slot = (x - 20) / 46;
          if (slot == 0) {
            Emit({{EncodableValue("type"), EncodableValue(std::string("prev"))}});
          } else if (slot == 1) {
            Emit({{EncodableValue("type"), EncodableValue(std::string("toggle"))}});
          } else if (slot == 2) {
            Emit({{EncodableValue("type"), EncodableValue(std::string("next"))}});
          } else if (slot == 3) {
            if (!more_items_.empty()) {
              sheet_kind_ = "more";
              sheet_title_ = L"更多";
              sheet_subtitle_.clear();
              sheet_items_ = more_items_;
              sheet_selected_ = 0;
              EnsureClasses();
              LayoutModal();
            } else {
              Emit({{EncodableValue("type"), EncodableValue("more")},
                    {EncodableValue("id"), EncodableValue(std::string("open"))}});
            }
          }
        }
        return 0;
      }
      if (hwnd == center_play_.hwnd) {
        Emit({{EncodableValue("type"), EncodableValue("togglePlay")}});
        return 0;
      }
      if (hwnd == episodes_.hwnd) {
        const int idx = (y - 44) / 40;
        if (idx >= 0 && idx < static_cast<int>(episode_lines_.size())) {
          Emit({{EncodableValue("type"), EncodableValue("episode")},
                {EncodableValue("index"), EncodableValue(idx)}});
        }
        return 0;
      }
      if (hwnd == live_left_.hwnd) {
        if (y > rc.bottom - 36) {
          Emit({{EncodableValue("type"), EncodableValue("collapseLiveLeft")}});
          return 0;
        }
        // 无分组时退化为单列频道（兼容旧 liveLeft）
        if (groups_.empty()) {
          const int idx = (y - 8) / 36;
          if (idx >= 0 && idx < static_cast<int>(channels_.size())) {
            channel_selected_ = idx;
            Emit({{EncodableValue("type"), EncodableValue("liveLeft")},
                  {EncodableValue("index"), EncodableValue(idx)}});
            InvalidateRect(hwnd, nullptr, TRUE);
          }
          return 0;
        }
        const int gW = 72;
        const int cW = 150;
        if (x < gW) {
          const int idx = (y - 8) / 40;
          if (idx >= 0 && idx < static_cast<int>(groups_.size())) {
            group_selected_ = idx;
            Emit({{EncodableValue("type"), EncodableValue("group")},
                  {EncodableValue("index"), EncodableValue(idx)}});
            InvalidateRect(hwnd, nullptr, TRUE);
          }
        } else if (x < gW + cW) {
          const int idx = (y - 8) / 36;
          if (idx >= 0 && idx < static_cast<int>(channels_.size())) {
            channel_selected_ = idx;
            Emit({{EncodableValue("type"), EncodableValue("liveLeft")},
                  {EncodableValue("index"), EncodableValue(idx)}});
            Emit({{EncodableValue("type"), EncodableValue("channel")},
                  {EncodableValue("index"), EncodableValue(idx)}});
            InvalidateRect(hwnd, nullptr, TRUE);
          }
        } else {
          if (y < 36) {
            const int idx = (x - gW - cW - 4) / 56;
            if (idx >= 0 && idx < static_cast<int>(epg_days_.size())) {
              epg_day_selected_ = idx;
              Emit({{EncodableValue("type"), EncodableValue("epgDay")},
                    {EncodableValue("index"), EncodableValue(idx)}});
              InvalidateRect(hwnd, nullptr, TRUE);
            }
          } else {
            const int idx = (y - 38) / 32;
            if (idx >= 0 && idx < static_cast<int>(epg_programs_.size())) {
              epg_program_selected_ = idx;
              Emit({{EncodableValue("type"), EncodableValue("epg")},
                    {EncodableValue("index"), EncodableValue(idx)}});
            }
          }
        }
        return 0;
      }
      if (hwnd == live_right_.hwnd) {
        const int idx = (y - 48) / 50;
        if (idx >= 0 && idx < static_cast<int>(live_right_items_.size())) {
          Emit({{EncodableValue("type"), EncodableValue("liveRight")},
                {EncodableValue("index"), EncodableValue(idx)},
                {EncodableValue("id"), EncodableValue(live_right_items_[idx].id)}});
        }
        return 0;
      }
      return 0;
    }
    case WM_ERASEBKGND:
      return 1;
    default:
      return DefWindowProcW(hwnd, msg, wParam, lParam);
  }
}

void KotvWinChrome::IngestDanmaku(const EncodableMap* args) {
  if (!args) return;
  if (args->count(EncodableValue("enabled")))
    danmaku_enabled_ = GetBool(*args, "enabled", danmaku_enabled_);
  if (args->count(EncodableValue("fontSize")))
    danmaku_font_ = GetDouble(*args, "fontSize", danmaku_font_);
  if (args->count(EncodableValue("opacity")))
    danmaku_opacity_ = GetDouble(*args, "opacity", danmaku_opacity_);
  if (args->count(EncodableValue("durationMs")))
    danmaku_duration_ms_ = GetInt(*args, "durationMs", danmaku_duration_ms_);
  if (args->count(EncodableValue("fixedDurationMs")))
    danmaku_fixed_ms_ = GetInt(*args, "fixedDurationMs", danmaku_fixed_ms_);
  else if (args->count(EncodableValue("fixedMs")))
    danmaku_fixed_ms_ = GetInt(*args, "fixedMs", danmaku_fixed_ms_);
  if (args->count(EncodableValue("rows")))
    danmaku_rows_ = GetInt(*args, "rows", danmaku_rows_);
  if (args->count(EncodableValue("showScroll")))
    danmaku_show_scroll_ = GetBool(*args, "showScroll", danmaku_show_scroll_);
  if (args->count(EncodableValue("showTop")))
    danmaku_show_top_ = GetBool(*args, "showTop", danmaku_show_top_);
  if (args->count(EncodableValue("showBottom")))
    danmaku_show_bottom_ = GetBool(*args, "showBottom", danmaku_show_bottom_);
  if (args->count(EncodableValue("showReverse")))
    danmaku_show_reverse_ = GetBool(*args, "showReverse", danmaku_show_reverse_);

  const auto it = args->find(EncodableValue("items"));
  if (it != args->end() && std::holds_alternative<flutter::EncodableList>(it->second)) {
    danmaku_items_.clear();
    for (const auto& v : std::get<flutter::EncodableList>(it->second)) {
      if (!std::holds_alternative<EncodableMap>(v)) continue;
      const auto& row = std::get<EncodableMap>(v);
      DanmakuItem d;
      d.time = GetDouble(row, "t");
      if (d.time == 0) d.time = GetDouble(row, "time");
      d.content = Utf8ToWide(GetString(row, "c"));
      if (d.content.empty()) d.content = Utf8ToWide(GetString(row, "content"));
      d.mode = GetInt(row, "m", GetInt(row, "mode", 1));
      d.color = GetInt(row, "color", 0xFFFFFF);
      d.size = GetInt(row, "size", 25);
      if (!d.content.empty()) danmaku_items_.push_back(std::move(d));
    }
    std::sort(danmaku_items_.begin(), danmaku_items_.end(),
              [](const DanmakuItem& a, const DanmakuItem& b) { return a.time < b.time; });
  }
  if (enabled_) LayoutDanmaku();
  if (danmaku_hwnd_) InvalidateRect(danmaku_hwnd_, nullptr, FALSE);
}

void KotvWinChrome::IngestSheet(const EncodableMap* args) {
  if (!args) return;
  sheet_kind_ = GetString(*args, "kind");
  if (sheet_kind_.empty()) {
    CloseSheet();
    return;
  }
  sheet_title_ = Utf8ToWide(GetString(*args, "title"));
  sheet_subtitle_ = Utf8ToWide(GetString(*args, "subtitle"));
  sheet_items_ = ParseLineItems(*args, "items");
  sheet_selected_ = GetInt(*args, "selected", 0);
  EnsureClasses();
  LayoutModal();
}

void KotvWinChrome::IngestUpdate(const EncodableMap* args) {
  if (!args) return;
  if (args->count(EncodableValue("mode"))) mode_ = GetString(*args, "mode");
  if (args->count(EncodableValue("anchorScreen"))) {
    const auto it = args->find(EncodableValue("anchorScreen"));
    if (it != args->end() && std::holds_alternative<EncodableMap>(it->second)) {
      const auto& a = std::get<EncodableMap>(it->second);
      anchor_screen_l_ = GetDouble(a, "left");
      anchor_screen_t_ = GetDouble(a, "top");
      anchor_screen_w_ = GetDouble(a, "width");
      anchor_screen_h_ = GetDouble(a, "height");
      anchor_valid_ = anchor_screen_w_ >= 8 && anchor_screen_h_ >= 8;
    } else {
      anchor_valid_ = false;
    }
  }
  if (args->count(EncodableValue("volume"))) volume_ = GetDouble(*args, "volume", volume_);
  if (args->count(EncodableValue("showDirect"))) show_direct_ = GetBool(*args, "showDirect");
  if (args->count(EncodableValue("directOn"))) direct_on_ = GetBool(*args, "directOn");
  if (args->count(EncodableValue("miniActive"))) mini_active_ = GetBool(*args, "miniActive");
  if (args->count(EncodableValue("title"))) title_ = Utf8ToWide(GetString(*args, "title"));
  if (args->count(EncodableValue("subtitle")))
    subtitle_ = Utf8ToWide(GetString(*args, "subtitle"));
  if (args->count(EncodableValue("resolution"))) {
    const auto res = GetString(*args, "resolution");
    if (!res.empty()) subtitle_ = L"[ " + Utf8ToWide(res) + L" ]";
  }
  if (args->count(EncodableValue("clock"))) clock_ = Utf8ToWide(GetString(*args, "clock"));
  if (args->count(EncodableValue("endsAt"))) ends_at_ = Utf8ToWide(GetString(*args, "endsAt"));
  if (args->count(EncodableValue("positionLabel")))
    pos_label_ = Utf8ToWide(GetString(*args, "positionLabel"));
  if (args->count(EncodableValue("durationLabel")))
    dur_label_ = Utf8ToWide(GetString(*args, "durationLabel"));
  if (args->count(EncodableValue("channelNo")))
    channel_no_ = Utf8ToWide(GetString(*args, "channelNo"));
  if (args->count(EncodableValue("channelName")))
    channel_name_ = Utf8ToWide(GetString(*args, "channelName"));
  if (args->count(EncodableValue("channelProgram")))
    channel_prog_ = Utf8ToWide(GetString(*args, "channelProgram"));
  if (args->count(EncodableValue("channelTicker")))
    channel_ticker_ = Utf8ToWide(GetString(*args, "channelTicker"));
  if (args->count(EncodableValue("channelText"))) {
    // 旧扁平频道条文案 → 拆到 name
    channel_name_ = Utf8ToWide(GetString(*args, "channelText"));
  }

  if (args->count(EncodableValue("episodes")))
    episode_lines_ = GetStringList(*args, "episodes");
  if (args->count(EncodableValue("episodeSelected")))
    episode_selected_ = GetInt(*args, "episodeSelected", -1);
  if (args->count(EncodableValue("groups"))) groups_ = GetStringList(*args, "groups");
  if (args->count(EncodableValue("groupSelected")))
    group_selected_ = GetInt(*args, "groupSelected", -1);
  if (args->count(EncodableValue("channels"))) channels_ = GetStringList(*args, "channels");
  if (args->count(EncodableValue("channelSelected")))
    channel_selected_ = GetInt(*args, "channelSelected", -1);
  // 兼容旧扁平 liveLeft
  if (args->count(EncodableValue("liveLeft"))) {
    const auto flat = GetStringList(*args, "liveLeft");
    if (channels_.empty()) channels_ = flat;
    if (args->count(EncodableValue("liveLeftSelected")))
      channel_selected_ = GetInt(*args, "liveLeftSelected", -1);
  }
  if (args->count(EncodableValue("epgDays"))) epg_days_ = GetStringList(*args, "epgDays");
  if (args->count(EncodableValue("epgDaySelected")))
    epg_day_selected_ = GetInt(*args, "epgDaySelected", 0);
  if (args->count(EncodableValue("epgPrograms")))
    epg_programs_ = GetStringList(*args, "epgPrograms");
  if (args->count(EncodableValue("epgProgramSelected")))
    epg_program_selected_ = GetInt(*args, "epgProgramSelected", -1);

  live_right_items_ = ParseLineItems(*args, "liveRightItems");
  if (live_right_items_.empty() && args->count(EncodableValue("liveRight"))) {
    // 字符串列表或结构化
    live_right_items_ = ParseLineItems(*args, "liveRight");
    if (live_right_items_.empty()) {
      const auto legacy = GetUtf8List(*args, "liveRight");
      for (size_t i = 0; i < legacy.size(); ++i) {
        LineItem it;
        it.id = std::to_string(i);
        it.label = Utf8ToWide(legacy[i]);
        live_right_items_.push_back(std::move(it));
      }
    }
  }
  if (args->count(EncodableValue("moreItems")))
    more_items_ = ParseLineItems(*args, "moreItems");

  top_visible_ = GetBool(*args, "top", top_visible_);
  bottom_visible_ = GetBool(*args, "bottom", bottom_visible_);
  episodes_visible_ = GetBool(*args, "episodesVisible", episodes_visible_);
  live_left_visible_ = GetBool(*args, "liveLeftVisible", live_left_visible_);
  live_right_visible_ = GetBool(*args, "liveRightVisible", live_right_visible_);
  channel_visible_ = GetBool(*args, "channelVisible", channel_visible_);
  center_visible_ = GetBool(*args, "centerVisible", center_visible_);
  playing_ = GetBool(*args, "playing", playing_);
  buffering_ = GetBool(*args, "buffering", buffering_);
  progress_ = GetDouble(*args, "progress", progress_);
  if (args->count(EncodableValue("positionSec")))
    position_sec_ = GetDouble(*args, "positionSec", position_sec_);
  else if (args->count(EncodableValue("position")))
    position_sec_ = GetDouble(*args, "position", position_sec_);
  rate_ = GetDouble(*args, "rate", rate_);
  if (args->count(EncodableValue("actions"))) actions_ = GetUtf8List(*args, "actions");

  if (args->find(EncodableValue("danmaku")) != args->end() &&
      std::holds_alternative<EncodableMap>(args->at(EncodableValue("danmaku")))) {
    const auto& dm = std::get<EncodableMap>(args->at(EncodableValue("danmaku")));
    IngestDanmaku(&dm);
  }
}

void KotvWinChrome::HandleMethod(const std::string& method, const EncodableMap* args,
                                 std::function<void(EncodableValue)> success,
                                 std::function<void(const std::string&, const std::string&)> error) {
  (void)error;
  if (method == "isAvailable") {
    success(EncodableValue(true));
    return;
  }
  if (method == "setEnabled") {
    enabled_ = args ? GetBool(*args, "enabled") : false;
    CloseSheet();
    if (enabled_) {
      EnsureClasses();
      Layout();
    } else {
      DestroyAll();
    }
    success(EncodableValue(true));
    return;
  }
  if (method == "setDanmaku") {
    IngestDanmaku(args);
    success(EncodableValue(true));
    return;
  }
  if (method == "update") {
    IngestUpdate(args);
    if (enabled_) Layout();
    success(EncodableValue(true));
    return;
  }
  if (method == "layout") {
    if (enabled_) Layout();
    success(EncodableValue(true));
    return;
  }
  if (method == "showSheet") {
    EnsureClasses();
    IngestSheet(args);
    success(EncodableValue(true));
    return;
  }
  if (method == "hideSheet") {
    CloseSheet();
    success(EncodableValue(true));
    return;
  }
  success(EncodableValue(false));
}

// ---------------------------------------------------------------------------
// Plugin registration（MethodChannel 回传 event，与 Dart setMethodCallHandler 对齐）
// ---------------------------------------------------------------------------

class KotvWinChromePlugin : public flutter::Plugin {
 public:
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows* registrar) {
    auto plugin = std::make_unique<KotvWinChromePlugin>(registrar);
    registrar->AddPlugin(std::move(plugin));
  }

  explicit KotvWinChromePlugin(flutter::PluginRegistrarWindows* registrar)
      : chrome_(registrar) {
    channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
        registrar->messenger(), "kotv_win_chrome",
        &flutter::StandardMethodCodec::GetInstance());
    channel_->SetMethodCallHandler(
        [this](const flutter::MethodCall<flutter::EncodableValue>& call,
               std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
          const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
          auto shared =
              std::shared_ptr<flutter::MethodResult<flutter::EncodableValue>>(std::move(result));
          chrome_.HandleMethod(
              call.method_name(), args,
              [shared](flutter::EncodableValue v) { shared->Success(std::move(v)); },
              [shared](const std::string& code, const std::string& msg) {
                shared->Error(code, msg);
              });
        });
    chrome_.SetEventSink([this](flutter::EncodableMap map) {
      channel_->InvokeMethod(
          "event", std::make_unique<flutter::EncodableValue>(flutter::EncodableValue(std::move(map))));
    });
  }

 private:
  KotvWinChrome chrome_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
};

void KotvWinChromeRegisterWithRegistrar(FlutterDesktopPluginRegistrarRef registrar) {
  KotvWinChromePlugin::RegisterWithRegistrar(
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar));
}
