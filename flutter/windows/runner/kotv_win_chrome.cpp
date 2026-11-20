#include "kotv_win_chrome.h"

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>

#include <windowsx.h>

#include <algorithm>
#include <cmath>
#include <functional>
#include <memory>

namespace {

using flutter::EncodableList;
using flutter::EncodableMap;
using flutter::EncodableValue;

// Win7 顶层 layered 色键透明（子窗 layered 仅 Win8+）。
constexpr COLORREF kDanmakuKey = RGB(1, 0, 1);
constexpr UINT_PTR kDanmakuTimerId = 77;

std::string ArgString(const EncodableMap* m, const char* key,
                      const std::string& def = "") {
  if (!m) return def;
  auto it = m->find(EncodableValue(key));
  if (it == m->end()) return def;
  if (const auto* s = std::get_if<std::string>(&it->second)) return *s;
  return def;
}

bool ArgBool(const EncodableMap* m, const char* key, bool def = false) {
  if (!m) return def;
  auto it = m->find(EncodableValue(key));
  if (it == m->end()) return def;
  if (const auto* b = std::get_if<bool>(&it->second)) return *b;
  return def;
}

double ArgDouble(const EncodableMap* m, const char* key, double def = 0) {
  if (!m) return def;
  auto it = m->find(EncodableValue(key));
  if (it == m->end()) return def;
  if (const auto* d = std::get_if<double>(&it->second)) return *d;
  if (const auto* i = std::get_if<int32_t>(&it->second)) return *i;
  if (const auto* i = std::get_if<int64_t>(&it->second)) return static_cast<double>(*i);
  return def;
}

int ArgInt(const EncodableMap* m, const char* key, int def = 0) {
  return static_cast<int>(ArgDouble(m, key, def));
}

std::vector<std::string> ArgStringList(const EncodableMap* m, const char* key) {
  std::vector<std::string> out;
  if (!m) return out;
  auto it = m->find(EncodableValue(key));
  if (it == m->end()) return out;
  const auto* list = std::get_if<EncodableList>(&it->second);
  if (!list) return out;
  for (const auto& v : *list) {
    if (const auto* s = std::get_if<std::string>(&v)) out.push_back(*s);
  }
  return out;
}

std::wstring Utf8ToWide(const std::string& s) {
  if (s.empty()) return L"";
  int n = MultiByteToWideChar(CP_UTF8, 0, s.c_str(), -1, nullptr, 0);
  if (n <= 0) return L"";
  std::wstring w(static_cast<size_t>(n - 1), L'\0');
  MultiByteToWideChar(CP_UTF8, 0, s.c_str(), -1, w.data(), n);
  return w;
}

std::vector<std::wstring> ToWideList(const std::vector<std::string>& in) {
  std::vector<std::wstring> out;
  out.reserve(in.size());
  for (const auto& s : in) out.push_back(Utf8ToWide(s));
  return out;
}

COLORREF RgbFromDanmaku(int color) {
  // B 站色通常为 0xRRGGBB
  const int r = (color >> 16) & 0xFF;
  const int g = (color >> 8) & 0xFF;
  const int b = color & 0xFF;
  return RGB(r, g, b);
}

class KotvWinChromePlugin : public flutter::Plugin {
 public:
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows* registrar) {
    auto plugin = std::make_unique<KotvWinChromePlugin>(registrar);
    registrar->AddPlugin(std::move(plugin));
  }

  explicit KotvWinChromePlugin(flutter::PluginRegistrarWindows* registrar)
      : chrome_(std::make_unique<KotvWinChrome>(registrar)) {
    channel_ = std::make_unique<flutter::MethodChannel<EncodableValue>>(
        registrar->messenger(), "kotv_win_chrome",
        &flutter::StandardMethodCodec::GetInstance());
    channel_->SetMethodCallHandler(
        [this](const auto& call, auto result) {
          const auto* args = std::get_if<EncodableMap>(call.arguments());
          auto shared =
              std::shared_ptr<flutter::MethodResult<EncodableValue>>(
                  std::move(result));
          chrome_->HandleMethod(
              call.method_name(), args,
              [shared](EncodableValue v) { shared->Success(v); },
              [shared](const std::string& code, const std::string& msg) {
                shared->Error(code, msg);
              });
        });
    chrome_->SetEventSink([this](EncodableMap map) {
      channel_->InvokeMethod(
          "event", std::make_unique<EncodableValue>(EncodableValue(map)));
    });
  }

 private:
  std::unique_ptr<KotvWinChrome> chrome_;
  std::unique_ptr<flutter::MethodChannel<EncodableValue>> channel_;
};

}  // namespace

void KotvWinChromeRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar) {
  KotvWinChromePlugin::RegisterWithRegistrar(
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar));
}

KotvWinChrome::KotvWinChrome(flutter::PluginRegistrarWindows* registrar)
    : registrar_(registrar) {}

KotvWinChrome::~KotvWinChrome() { DestroyAll(); }

void KotvWinChrome::SetEventSink(EventFn fn) { event_fn_ = std::move(fn); }

void KotvWinChrome::Emit(EncodableMap map) {
  if (event_fn_) event_fn_(std::move(map));
}

HWND KotvWinChrome::FlutterHwnd() const {
  return registrar_->GetView() ? registrar_->GetView()->GetNativeWindow()
                               : nullptr;
}

HWND KotvWinChrome::RootHwnd() const {
  HWND f = FlutterHwnd();
  return f ? GetAncestor(f, GA_ROOT) : nullptr;
}

void KotvWinChrome::EnsureClasses() {
  if (classes_ready_) return;
  WNDCLASSW wc{};
  wc.lpfnWndProc = KotvWinChrome::WndProc;
  wc.hInstance = GetModuleHandleW(nullptr);
  wc.hCursor = LoadCursor(nullptr, IDC_ARROW);
  wc.hbrBackground = reinterpret_cast<HBRUSH>(GetStockObject(BLACK_BRUSH));
  wc.lpszClassName = L"KotvWinChromePanel";
  RegisterClassW(&wc);

  WNDCLASSW dc{};
  dc.lpfnWndProc = KotvWinChrome::DanmakuWndProc;
  dc.hInstance = GetModuleHandleW(nullptr);
  dc.hCursor = LoadCursor(nullptr, IDC_ARROW);
  dc.hbrBackground = nullptr;
  dc.lpszClassName = L"KotvWinChromeDanmaku";
  RegisterClassW(&dc);
  classes_ready_ = true;
}

HWND KotvWinChrome::CreateChildPanel(const wchar_t* title) {
  HWND parent = FlutterHwnd();
  if (!parent) return nullptr;
  HWND hwnd = CreateWindowExW(
      WS_EX_NOPARENTNOTIFY, L"KotvWinChromePanel", title,
      WS_CHILD | WS_CLIPSIBLINGS, 0, 0, 10, 10, parent, nullptr,
      GetModuleHandleW(nullptr), this);
  if (hwnd) {
    SetWindowLongPtrW(hwnd, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(this));
  }
  return hwnd;
}

HWND KotvWinChrome::CreateDanmakuLayer() {
  HWND owner = RootHwnd();
  if (!owner) return nullptr;
  HWND hwnd = CreateWindowExW(
      WS_EX_LAYERED | WS_EX_TRANSPARENT | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE |
          WS_EX_TOPMOST,
      L"KotvWinChromeDanmaku", L"", WS_POPUP, 0, 0, 10, 10, owner, nullptr,
      GetModuleHandleW(nullptr), this);
  if (!hwnd) return nullptr;
  SetWindowLongPtrW(hwnd, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(this));
  SetLayeredWindowAttributes(hwnd, kDanmakuKey, 0, LWA_COLORKEY);
  return hwnd;
}

void KotvWinChrome::DestroyAll() {
  if (danmaku_timer_ && danmaku_hwnd_) {
    KillTimer(danmaku_hwnd_, danmaku_timer_);
    danmaku_timer_ = 0;
  }
  auto kill = [](Panel& p) {
    if (p.hwnd) {
      DestroyWindow(p.hwnd);
      p.hwnd = nullptr;
    }
  };
  kill(top_);
  kill(bottom_);
  kill(episodes_);
  kill(live_left_);
  kill(live_right_);
  kill(channel_info_);
  kill(center_play_);
  if (danmaku_hwnd_) {
    DestroyWindow(danmaku_hwnd_);
    danmaku_hwnd_ = nullptr;
  }
  enabled_ = false;
}

void KotvWinChrome::ShowPanel(Panel& p, bool show, int x, int y, int w, int h) {
  if (!p.hwnd) return;
  if (!show || w < 1 || h < 1) {
    ShowWindow(p.hwnd, SW_HIDE);
    return;
  }
  SetWindowPos(p.hwnd, HWND_TOP, x, y, w, h,
               SWP_NOACTIVATE | SWP_SHOWWINDOW);
  InvalidateRect(p.hwnd, nullptr, TRUE);
}

void KotvWinChrome::LayoutDanmaku() {
  HWND root = RootHwnd();
  HWND flutter = FlutterHwnd();
  if (!danmaku_hwnd_ || !root || !flutter) return;
  RECT rc{};
  GetClientRect(flutter, &rc);
  POINT tl{rc.left, rc.top};
  POINT br{rc.right, rc.bottom};
  ClientToScreen(flutter, &tl);
  ClientToScreen(flutter, &br);
  const int w = br.x - tl.x;
  const int h = br.y - tl.y;
  const bool show = enabled_ && (danmaku_enabled_ || buffering_);
  if (!show || w < 1 || h < 1) {
    ShowWindow(danmaku_hwnd_, SW_HIDE);
    return;
  }
  SetWindowPos(danmaku_hwnd_, HWND_TOPMOST, tl.x, tl.y, w, h,
               SWP_NOACTIVATE | SWP_SHOWWINDOW);
  InvalidateRect(danmaku_hwnd_, nullptr, TRUE);
}

void KotvWinChrome::Layout() {
  HWND parent = FlutterHwnd();
  if (!parent || !enabled_) return;
  RECT rc{};
  GetClientRect(parent, &rc);
  const int W = rc.right - rc.left;
  const int H = rc.bottom - rc.top;

  const int top_h = 52;
  const int bottom_h = 92;
  const int ep_w = 280;
  const int live_w = 320;
  const int ch_h = 72;
  const int center_s = 64;

  ShowPanel(top_, top_visible_, 0, 0, W, top_h);
  ShowPanel(bottom_, bottom_visible_, 0, H - bottom_h, W, bottom_h);
  ShowPanel(episodes_, episodes_visible_, W - ep_w, top_visible_ ? top_h : 0, ep_w,
            H - (top_visible_ ? top_h : 0) - (bottom_visible_ ? bottom_h : 0));
  ShowPanel(live_left_, live_left_visible_, 0, 0, live_w, H);
  ShowPanel(live_right_, live_right_visible_, W - live_w, 0, live_w, H);
  ShowPanel(channel_info_, channel_visible_, live_left_visible_ ? live_w : 0,
            H - ch_h - (bottom_visible_ ? bottom_h : 0),
            W - (live_left_visible_ ? live_w : 0) -
                (live_right_visible_ ? live_w : 0),
            ch_h);
  ShowPanel(center_play_, center_visible_ && !buffering_, (W - center_s) / 2,
            (H - center_s) / 2, center_s, center_s);
  LayoutDanmaku();
}

void KotvWinChrome::PaintDark(HWND hwnd, HDC hdc, const RECT& rc,
                              const std::wstring& title,
                              const std::vector<std::wstring>* lines,
                              int selected) {
  // 接近 Flutter 全屏栏：0xF0120A1C / 半透明黑感
  HBRUSH bg = CreateSolidBrush(RGB(18, 10, 28));
  FillRect(hdc, &rc, bg);
  DeleteObject(bg);

  SetBkMode(hdc, TRANSPARENT);
  SetTextColor(hdc, RGB(255, 255, 255));
  HFONT font = CreateFontW(18, 0, 0, 0, FW_BOLD, FALSE, FALSE, FALSE,
                           DEFAULT_CHARSET, OUT_DEFAULT_PRECIS,
                           CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY,
                           DEFAULT_PITCH | FF_SWISS, L"Segoe UI");
  HFONT old = (HFONT)SelectObject(hdc, font);

  if (hwnd == top_.hwnd) {
    // 左侧红条（Flutter 0xFFE52D27）
    RECT accent = {rc.left + 10, rc.top + 12, rc.left + 14, rc.bottom - 12};
    HBRUSH red = CreateSolidBrush(RGB(229, 45, 39));
    FillRect(hdc, &accent, red);
    DeleteObject(red);
    RECT tr = rc;
    tr.left += 24;
    tr.top += 10;
    tr.right -= 72;
    if (!title.empty()) {
      DrawTextW(hdc, title.c_str(), -1, &tr,
                DT_LEFT | DT_TOP | DT_END_ELLIPSIS | DT_SINGLELINE);
    }
    RECT exit_rc = {rc.right - 64, rc.top + 12, rc.right - 12, rc.bottom - 12};
    SetTextColor(hdc, RGB(230, 230, 235));
    DrawTextW(hdc, L"退出", -1, &exit_rc, DT_CENTER | DT_VCENTER | DT_SINGLELINE);
  } else if (!title.empty() && hwnd != bottom_.hwnd) {
    RECT tr = rc;
    tr.left += 16;
    tr.top += 12;
    tr.right -= (hwnd == episodes_.hwnd ? 48 : 16);
    DrawTextW(hdc, title.c_str(), -1, &tr,
              DT_LEFT | DT_TOP | DT_END_ELLIPSIS | DT_SINGLELINE);
    if (hwnd == episodes_.hwnd) {
      RECT close_rc = {rc.right - 40, rc.top + 8, rc.right - 8, rc.top + 36};
      DrawTextW(hdc, L"×", -1, &close_rc, DT_CENTER | DT_VCENTER | DT_SINGLELINE);
    }
  }

  if (hwnd == bottom_.hwnd) {
    if (!bottom_text_.empty()) {
      RECT tr = {rc.left + 16, rc.top + 6, rc.right - 16, rc.top + 28};
      SetTextColor(hdc, RGB(220, 220, 225));
      DrawTextW(hdc, bottom_text_.c_str(), -1, &tr,
                DT_LEFT | DT_TOP | DT_END_ELLIPSIS | DT_SINGLELINE);
    }
    // 动作行
    if (!actions_.empty()) {
      HFONT act = CreateFontW(15, 0, 0, 0, FW_SEMIBOLD, FALSE, FALSE, FALSE,
                              DEFAULT_CHARSET, OUT_DEFAULT_PRECIS,
                              CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY,
                              DEFAULT_PITCH | FF_SWISS, L"Segoe UI");
      SelectObject(hdc, act);
      const int n = static_cast<int>(actions_.size());
      const int slot = (std::max)(48, (rc.right - rc.left - 24) / (std::max)(1, n));
      for (int i = 0; i < n; ++i) {
        RECT ar = {rc.left + 12 + i * slot, rc.top + 30,
                   rc.left + 12 + (i + 1) * slot - 4, rc.top + 54};
        std::wstring label;
        const auto& a = actions_[i];
        if (a == "prev")
          label = L"上一集";
        else if (a == "toggle")
          label = playing_ ? L"暂停" : L"播放";
        else if (a == "next")
          label = L"下一集";
        else if (a == "speed")
          label = L"倍速";
        else if (a == "replay")
          label = L"重播";
        else if (a == "episodes")
          label = L"选集";
        else
          label = Utf8ToWide(a);
        SetTextColor(hdc, RGB(255, 255, 255));
        DrawTextW(hdc, label.c_str(), -1, &ar,
                  DT_CENTER | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS);
      }
      DeleteObject(act);
      SelectObject(hdc, font);
    }
    RECT bar = {rc.left + 16, rc.bottom - 22, rc.right - 16, rc.bottom - 14};
    HBRUSH track = CreateSolidBrush(RGB(60, 60, 70));
    FillRect(hdc, &bar, track);
    DeleteObject(track);
    int fill = static_cast<int>((bar.right - bar.left) *
                                (std::max)(0.0, (std::min)(1.0, progress_)));
    RECT fill_rc = {bar.left, bar.top, bar.left + fill, bar.bottom};
    HBRUSH fill_br = CreateSolidBrush(RGB(80, 160, 255));
    FillRect(hdc, &fill_rc, fill_br);
    DeleteObject(fill_br);
  }

  if (hwnd == center_play_.hwnd) {
    HBRUSH disc = CreateSolidBrush(RGB(20, 20, 24));
    HGDIOBJ old_br = SelectObject(hdc, disc);
    HPEN pen = CreatePen(PS_SOLID, 1, RGB(80, 80, 90));
    HGDIOBJ old_pen = SelectObject(hdc, pen);
    Ellipse(hdc, rc.left + 4, rc.top + 4, rc.right - 4, rc.bottom - 4);
    SelectObject(hdc, old_br);
    SelectObject(hdc, old_pen);
    DeleteObject(disc);
    DeleteObject(pen);
    const wchar_t* glyph = playing_ ? L"❚❚" : L"▶";
    DrawTextW(hdc, glyph, -1, const_cast<RECT*>(&rc),
              DT_CENTER | DT_VCENTER | DT_SINGLELINE);
  }

  if (lines) {
    int y = title.empty() ? 12 : 40;
    HFONT row = CreateFontW(16, 0, 0, 0, FW_NORMAL, FALSE, FALSE, FALSE,
                            DEFAULT_CHARSET, OUT_DEFAULT_PRECIS,
                            CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY,
                            DEFAULT_PITCH | FF_SWISS, L"Segoe UI");
    SelectObject(hdc, row);
    for (int i = 0; i < static_cast<int>(lines->size()); ++i) {
      RECT lr = {rc.left + 12, y, rc.right - 12, y + 28};
      if (i == selected) {
        HBRUSH hi = CreateSolidBrush(RGB(40, 80, 140));
        FillRect(hdc, &lr, hi);
        DeleteObject(hi);
      }
      DrawTextW(hdc, (*lines)[i].c_str(), -1, &lr,
                DT_LEFT | DT_VCENTER | DT_END_ELLIPSIS | DT_SINGLELINE);
      y += 30;
      if (y > rc.bottom - 8) break;
    }
    DeleteObject(row);
  }

  if (hwnd == channel_info_.hwnd && !channel_text_.empty()) {
    RECT tr = rc;
    tr.left += 16;
    tr.top += 16;
    DrawTextW(hdc, channel_text_.c_str(), -1, &tr,
              DT_LEFT | DT_TOP | DT_WORDBREAK);
  }

  SelectObject(hdc, old);
  DeleteObject(font);
}

void KotvWinChrome::PaintDanmaku(HWND hwnd) {
  RECT rc{};
  GetClientRect(hwnd, &rc);
  const int W = rc.right - rc.left;
  const int H = rc.bottom - rc.top;
  if (W < 1 || H < 1) return;

  HDC screen = GetDC(hwnd);
  HDC mem = CreateCompatibleDC(screen);
  BITMAPINFO bmi{};
  bmi.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
  bmi.bmiHeader.biWidth = W;
  bmi.bmiHeader.biHeight = -H;
  bmi.bmiHeader.biPlanes = 1;
  bmi.bmiHeader.biBitCount = 32;
  bmi.bmiHeader.biCompression = BI_RGB;
  void* bits = nullptr;
  HBITMAP bmp = CreateDIBSection(mem, &bmi, DIB_RGB_COLORS, &bits, nullptr, 0);
  HGDIOBJ old_bmp = SelectObject(mem, bmp);

  // 填色键
  HBRUSH key = CreateSolidBrush(kDanmakuKey);
  FillRect(mem, &rc, key);
  DeleteObject(key);

  // 避开顶/底/侧栏，避免画在原生播控上
  const int pad_top = top_visible_ ? 52 : 8;
  const int pad_bottom = bottom_visible_ ? 92 : (channel_visible_ ? 72 : 8);
  const int pad_left = live_left_visible_ ? 320 : 0;
  const int pad_right = (live_right_visible_ || episodes_visible_) ? 280 : 0;
  const int usable_w = W - pad_left - pad_right;
  const int usable_h = H - pad_top - pad_bottom;

  SetBkMode(mem, TRANSPARENT);

  if (buffering_) {
    HFONT bf = CreateFontW(22, 0, 0, 0, FW_SEMIBOLD, FALSE, FALSE, FALSE,
                           DEFAULT_CHARSET, OUT_DEFAULT_PRECIS,
                           CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY,
                           DEFAULT_PITCH | FF_SWISS, L"Segoe UI");
    HGDIOBJ oldf = SelectObject(mem, bf);
    SetTextColor(mem, RGB(240, 240, 245));
    RECT tr = rc;
    DrawTextW(mem, L"缓冲中…", -1, &tr, DT_CENTER | DT_VCENTER | DT_SINGLELINE);
    SelectObject(mem, oldf);
    DeleteObject(bf);
  }

  if (danmaku_enabled_ && !danmaku_items_.empty() && usable_w > 40 &&
      usable_h > 40) {
    const double dur = (std::max)(1.0, danmaku_duration_ms_ / 1000.0);
    const double fixed = (std::max)(1.0, danmaku_fixed_ms_ / 1000.0);
    const double now = position_sec_;
    const int rows = (std::max)(1, danmaku_rows_);
    const int row_h = (std::max)(18, usable_h / rows);
    int on_screen = 0;
    const int max_on = 120;

    for (const auto& it : danmaku_items_) {
      if (on_screen >= max_on) break;
      const bool scroll = it.mode == 1 || it.mode == 6;
      const bool top = it.mode == 5;
      const bool bottom = it.mode == 4;
      if (scroll && !danmaku_show_scroll_) continue;
      if (it.mode == 6 && !danmaku_show_reverse_) continue;
      if (top && !danmaku_show_top_) continue;
      if (bottom && !danmaku_show_bottom_) continue;
      if (!scroll && !top && !bottom) continue;

      const double life = scroll ? dur : fixed;
      const double age = now - it.time;
      if (age < -0.05 || age > life) continue;

      const double t = age / life;  // 0..1
      const int font_px = (std::max)(
          12, static_cast<int>(danmaku_font_ *
                               (it.size <= 18 ? 12.0 / 14.0
                                              : (it.size >= 36 ? 18.0 / 14.0 : 1.0))));
      HFONT font = CreateFontW(font_px, 0, 0, 0, FW_BOLD, FALSE, FALSE, FALSE,
                               DEFAULT_CHARSET, OUT_DEFAULT_PRECIS,
                               CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY,
                               DEFAULT_PITCH | FF_SWISS, L"Segoe UI");
      HGDIOBJ oldf = SelectObject(mem, font);
      SIZE sz{};
      GetTextExtentPoint32W(mem, it.content.c_str(),
                            static_cast<int>(it.content.size()), &sz);

      int x = 0;
      int y = pad_top;
      if (scroll) {
        // 用内容哈希稳到轨
        size_t hsh = 1469598103u;
        for (wchar_t c : it.content) hsh = (hsh ^ static_cast<size_t>(c)) * 1099511628211u;
        const int track = static_cast<int>(hsh % static_cast<size_t>(rows));
        y = pad_top + track * row_h;
        if (it.mode == 6) {
          // 逆向：左→右
          x = pad_left + static_cast<int>((usable_w + sz.cx) * t) - sz.cx;
        } else {
          // 滚动：右→左
          x = pad_left + usable_w -
              static_cast<int>((usable_w + sz.cx) * t);
        }
      } else if (top) {
        size_t hsh = 2166136261u;
        for (wchar_t c : it.content) hsh = (hsh ^ static_cast<size_t>(c)) * 16777619u;
        const int track = static_cast<int>(hsh % static_cast<size_t>((std::max)(1, rows / 2)));
        y = pad_top + track * row_h;
        x = pad_left + (usable_w - sz.cx) / 2;
      } else {
        size_t hsh = 2166136261u;
        for (wchar_t c : it.content) hsh = (hsh ^ static_cast<size_t>(c)) * 16777619u;
        const int track = static_cast<int>(hsh % static_cast<size_t>((std::max)(1, rows / 2)));
        y = H - pad_bottom - (track + 1) * row_h;
        x = pad_left + (usable_w - sz.cx) / 2;
      }

      COLORREF rgb = RgbFromDanmaku(it.color);
      // 近似透明度：opacity 低时略压暗
      if (danmaku_opacity_ < 0.99) {
        const double o = (std::max)(0.2, danmaku_opacity_);
        rgb = RGB(static_cast<int>(GetRValue(rgb) * o),
                  static_cast<int>(GetGValue(rgb) * o),
                  static_cast<int>(GetBValue(rgb) * o));
      }
      // 描边
      SetTextColor(mem, RGB(0, 0, 0));
      for (int dx = -1; dx <= 1; ++dx) {
        for (int dy = -1; dy <= 1; ++dy) {
          if (dx == 0 && dy == 0) continue;
          TextOutW(mem, x + dx, y + dy, it.content.c_str(),
                  static_cast<int>(it.content.size()));
        }
      }
      SetTextColor(mem, rgb);
      TextOutW(mem, x, y, it.content.c_str(), static_cast<int>(it.content.size()));
      SelectObject(mem, oldf);
      DeleteObject(font);
      ++on_screen;
    }
  }

  BitBlt(screen, 0, 0, W, H, mem, 0, 0, SRCCOPY);
  SelectObject(mem, old_bmp);
  DeleteObject(bmp);
  DeleteDC(mem);
  ReleaseDC(hwnd, screen);
}

LRESULT CALLBACK KotvWinChrome::WndProc(HWND hwnd, UINT msg, WPARAM wp,
                                        LPARAM lp) {
  auto* self =
      reinterpret_cast<KotvWinChrome*>(GetWindowLongPtrW(hwnd, GWLP_USERDATA));
  if (!self && msg == WM_NCCREATE) {
    auto* cs = reinterpret_cast<CREATESTRUCTW*>(lp);
    self = reinterpret_cast<KotvWinChrome*>(cs->lpCreateParams);
    SetWindowLongPtrW(hwnd, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(self));
  }
  if (self) return self->OnMessage(hwnd, msg, wp, lp);
  return DefWindowProcW(hwnd, msg, wp, lp);
}

LRESULT CALLBACK KotvWinChrome::DanmakuWndProc(HWND hwnd, UINT msg, WPARAM wp,
                                               LPARAM lp) {
  auto* self =
      reinterpret_cast<KotvWinChrome*>(GetWindowLongPtrW(hwnd, GWLP_USERDATA));
  if (!self && msg == WM_NCCREATE) {
    auto* cs = reinterpret_cast<CREATESTRUCTW*>(lp);
    self = reinterpret_cast<KotvWinChrome*>(cs->lpCreateParams);
    SetWindowLongPtrW(hwnd, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(self));
  }
  if (self) return self->OnDanmakuMessage(hwnd, msg, wp, lp);
  return DefWindowProcW(hwnd, msg, wp, lp);
}

LRESULT KotvWinChrome::OnDanmakuMessage(HWND hwnd, UINT msg, WPARAM wp,
                                        LPARAM lp) {
  switch (msg) {
    case WM_TIMER:
      if (wp == kDanmakuTimerId) {
        LayoutDanmaku();
        return 0;
      }
      break;
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
      break;
  }
  return DefWindowProcW(hwnd, msg, wp, lp);
}

LRESULT KotvWinChrome::OnMessage(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
  switch (msg) {
    case WM_PAINT: {
      PAINTSTRUCT ps;
      HDC hdc = BeginPaint(hwnd, &ps);
      RECT rc;
      GetClientRect(hwnd, &rc);
      std::wstring title;
      const std::vector<std::wstring>* lines = nullptr;
      int selected = -1;
      if (hwnd == top_.hwnd) {
        title = title_;
        if (!subtitle_.empty()) title += L"  ·  " + subtitle_;
      } else if (hwnd == episodes_.hwnd) {
        title = L"选集";
        lines = &episode_lines_;
        selected = episode_selected_;
      } else if (hwnd == live_left_.hwnd) {
        title = L"频道";
        lines = &live_left_lines_;
        selected = live_left_selected_;
      } else if (hwnd == live_right_.hwnd) {
        title = L"设置";
        lines = &live_right_lines_;
      }
      PaintDark(hwnd, hdc, rc, title, lines, selected);
      EndPaint(hwnd, &ps);
      return 0;
    }
    case WM_LBUTTONUP: {
      const int x = GET_X_LPARAM(lp);
      const int y = GET_Y_LPARAM(lp);
      if (hwnd == center_play_.hwnd) {
        Emit({{EncodableValue("type"), EncodableValue("togglePlay")}});
        return 0;
      }
      if (hwnd == top_.hwnd) {
        RECT rc;
        GetClientRect(hwnd, &rc);
        if (x >= rc.right - 64) {
          Emit({{EncodableValue("type"), EncodableValue("exit")}});
        }
        return 0;
      }
      if (hwnd == bottom_.hwnd) {
        RECT rc;
        GetClientRect(hwnd, &rc);
        if (y > rc.bottom - 28) {
          double p = (x - 16) / (std::max)(1.0, static_cast<double>(rc.right - 32));
          p = (std::max)(0.0, (std::min)(1.0, p));
          Emit({{EncodableValue("type"), EncodableValue("seekFraction")},
                {EncodableValue("value"), EncodableValue(p)}});
        } else if (y >= 28 && y <= 56 && !actions_.empty()) {
          const int n = static_cast<int>(actions_.size());
          const int slot =
              (std::max)(48, (rc.right - rc.left - 24) / (std::max)(1, n));
          const int idx = (x - 12) / slot;
          if (idx >= 0 && idx < n) {
            Emit({{EncodableValue("type"), EncodableValue(actions_[idx])}});
          }
        }
        return 0;
      }
      auto pick = [&](const std::vector<std::wstring>& lines, int y0,
                      const char* type) {
        int idx = (y - y0) / 30;
        if (idx >= 0 && idx < static_cast<int>(lines.size())) {
          Emit({{EncodableValue("type"), EncodableValue(type)},
                {EncodableValue("index"),
                 EncodableValue(static_cast<int32_t>(idx))}});
        }
      };
      if (hwnd == episodes_.hwnd) {
        RECT rc;
        GetClientRect(hwnd, &rc);
        if (y < 40 && x >= rc.right - 40) {
          Emit({{EncodableValue("type"), EncodableValue("closeEpisodes")}});
          return 0;
        }
        pick(episode_lines_, 40, "episode");
        return 0;
      }
      if (hwnd == live_left_.hwnd) {
        pick(live_left_lines_, 40, "liveLeft");
        return 0;
      }
      if (hwnd == live_right_.hwnd) {
        pick(live_right_lines_, 40, "liveRight");
        return 0;
      }
      return 0;
    }
    case WM_ERASEBKGND:
      return 1;
    default:
      break;
  }
  return DefWindowProcW(hwnd, msg, wp, lp);
}

void KotvWinChrome::IngestDanmaku(const EncodableMap* args) {
  if (!args) return;
  if (args->count(EncodableValue("enabled")))
    danmaku_enabled_ = ArgBool(args, "enabled");
  if (args->count(EncodableValue("fontSize")))
    danmaku_font_ = ArgDouble(args, "fontSize", danmaku_font_);
  if (args->count(EncodableValue("opacity")))
    danmaku_opacity_ = ArgDouble(args, "opacity", danmaku_opacity_);
  if (args->count(EncodableValue("durationMs")))
    danmaku_duration_ms_ = ArgInt(args, "durationMs", danmaku_duration_ms_);
  if (args->count(EncodableValue("fixedDurationMs")))
    danmaku_fixed_ms_ = ArgInt(args, "fixedDurationMs", danmaku_fixed_ms_);
  if (args->count(EncodableValue("rows")))
    danmaku_rows_ = ArgInt(args, "rows", danmaku_rows_);
  if (args->count(EncodableValue("showScroll")))
    danmaku_show_scroll_ = ArgBool(args, "showScroll", danmaku_show_scroll_);
  if (args->count(EncodableValue("showTop")))
    danmaku_show_top_ = ArgBool(args, "showTop", danmaku_show_top_);
  if (args->count(EncodableValue("showBottom")))
    danmaku_show_bottom_ = ArgBool(args, "showBottom", danmaku_show_bottom_);
  if (args->count(EncodableValue("showReverse")))
    danmaku_show_reverse_ = ArgBool(args, "showReverse", danmaku_show_reverse_);

  auto it = args->find(EncodableValue("items"));
  if (it != args->end()) {
    danmaku_items_.clear();
    const auto* list = std::get_if<EncodableList>(&it->second);
    if (list) {
      danmaku_items_.reserve(list->size());
      for (const auto& v : *list) {
        const auto* m = std::get_if<EncodableMap>(&v);
        if (!m) continue;
        DanmakuItem d;
        d.time = ArgDouble(m, "t");
        d.content = Utf8ToWide(ArgString(m, "c"));
        d.mode = ArgInt(m, "m", 1);
        d.color = ArgInt(m, "color", 0xFFFFFF);
        d.size = ArgInt(m, "size", 25);
        if (!d.content.empty()) danmaku_items_.push_back(std::move(d));
      }
      std::sort(danmaku_items_.begin(), danmaku_items_.end(),
                [](const DanmakuItem& a, const DanmakuItem& b) {
                  return a.time < b.time;
                });
    }
  }
}

void KotvWinChrome::HandleMethod(
    const std::string& method, const EncodableMap* args,
    std::function<void(EncodableValue)> success,
    std::function<void(const std::string&, const std::string&)> error) {
  (void)error;
  if (method == "isAvailable") {
    success(EncodableValue(true));
    return;
  }
  if (method == "setEnabled") {
    enabled_ = ArgBool(args, "enabled");
    if (enabled_) {
      EnsureClasses();
      if (!top_.hwnd) top_.hwnd = CreateChildPanel(L"top");
      if (!bottom_.hwnd) bottom_.hwnd = CreateChildPanel(L"bottom");
      if (!episodes_.hwnd) episodes_.hwnd = CreateChildPanel(L"episodes");
      if (!live_left_.hwnd) live_left_.hwnd = CreateChildPanel(L"liveLeft");
      if (!live_right_.hwnd) live_right_.hwnd = CreateChildPanel(L"liveRight");
      if (!channel_info_.hwnd)
        channel_info_.hwnd = CreateChildPanel(L"channel");
      if (!center_play_.hwnd) center_play_.hwnd = CreateChildPanel(L"center");
      if (!danmaku_hwnd_) danmaku_hwnd_ = CreateDanmakuLayer();
      if (danmaku_hwnd_ && !danmaku_timer_) {
        danmaku_timer_ = SetTimer(danmaku_hwnd_, kDanmakuTimerId, 33, nullptr);
      }
      Layout();
    } else {
      DestroyAll();
    }
    success(EncodableValue(true));
    return;
  }
  if (method == "setDanmaku") {
    IngestDanmaku(args);
    if (enabled_) LayoutDanmaku();
    success(EncodableValue(true));
    return;
  }
  if (method == "update") {
    if (args) {
      if (args->count(EncodableValue("title")))
        title_ = Utf8ToWide(ArgString(args, "title"));
      if (args->count(EncodableValue("subtitle")))
        subtitle_ = Utf8ToWide(ArgString(args, "subtitle"));
      if (args->count(EncodableValue("bottomText")))
        bottom_text_ = Utf8ToWide(ArgString(args, "bottomText"));
      if (args->count(EncodableValue("channelText")))
        channel_text_ = Utf8ToWide(ArgString(args, "channelText"));
      if (args->count(EncodableValue("episodes")))
        episode_lines_ = ToWideList(ArgStringList(args, "episodes"));
      if (args->count(EncodableValue("episodeSelected")))
        episode_selected_ = ArgInt(args, "episodeSelected", -1);
      if (args->count(EncodableValue("liveLeft")))
        live_left_lines_ = ToWideList(ArgStringList(args, "liveLeft"));
      if (args->count(EncodableValue("liveLeftSelected")))
        live_left_selected_ = ArgInt(args, "liveLeftSelected", -1);
      if (args->count(EncodableValue("liveRight")))
        live_right_lines_ = ToWideList(ArgStringList(args, "liveRight"));
      if (args->count(EncodableValue("progress")))
        progress_ = ArgDouble(args, "progress");
      if (args->count(EncodableValue("positionSec")))
        position_sec_ = ArgDouble(args, "positionSec");
      if (args->count(EncodableValue("rate")))
        rate_ = ArgDouble(args, "rate", 1.0);
      if (args->count(EncodableValue("playing")))
        playing_ = ArgBool(args, "playing", true);
      if (args->count(EncodableValue("buffering")))
        buffering_ = ArgBool(args, "buffering");
      if (args->count(EncodableValue("actions")))
        actions_ = ArgStringList(args, "actions");

      top_visible_ = ArgBool(args, "top", top_visible_);
      bottom_visible_ = ArgBool(args, "bottom", bottom_visible_);
      episodes_visible_ = ArgBool(args, "episodesVisible", episodes_visible_);
      live_left_visible_ = ArgBool(args, "liveLeftVisible", live_left_visible_);
      live_right_visible_ =
          ArgBool(args, "liveRightVisible", live_right_visible_);
      channel_visible_ = ArgBool(args, "channelVisible", channel_visible_);
      center_visible_ = ArgBool(args, "centerVisible", center_visible_);
    }
    if (enabled_) Layout();
    success(EncodableValue(true));
    return;
  }
  if (method == "layout") {
    if (enabled_) Layout();
    success(EncodableValue(true));
    return;
  }
  success(EncodableValue(false));
}
