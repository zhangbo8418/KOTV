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

KotvWinChrome* g_chrome = nullptr;

class KotvWinChromePlugin : public flutter::Plugin {
 public:
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows* registrar) {
    auto plugin = std::make_unique<KotvWinChromePlugin>(registrar);
    registrar->AddPlugin(std::move(plugin));
  }

  explicit KotvWinChromePlugin(flutter::PluginRegistrarWindows* registrar)
      : chrome_(std::make_unique<KotvWinChrome>(registrar)) {
    g_chrome = chrome_.get();
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
      channel_->InvokeMethod("event",
                             std::make_unique<EncodableValue>(EncodableValue(map)));
    });
  }

  ~KotvWinChromePlugin() override {
    if (g_chrome == chrome_.get()) g_chrome = nullptr;
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

void KotvWinChrome::EnsureClasses() {
  if (classes_ready_) return;
  WNDCLASSW wc{};
  wc.lpfnWndProc = KotvWinChrome::WndProc;
  wc.hInstance = GetModuleHandleW(nullptr);
  wc.hCursor = LoadCursor(nullptr, IDC_ARROW);
  wc.hbrBackground = reinterpret_cast<HBRUSH>(GetStockObject(BLACK_BRUSH));
  wc.lpszClassName = L"KotvWinChromePanel";
  RegisterClassW(&wc);
  classes_ready_ = true;
}

HWND KotvWinChrome::CreatePanel(const wchar_t* class_name, DWORD ex,
                                const wchar_t* title) {
  HWND parent = FlutterHwnd();
  if (!parent) return nullptr;
  HWND hwnd = CreateWindowExW(
      ex | WS_EX_NOPARENTNOTIFY, class_name, title,
      WS_CHILD | WS_CLIPSIBLINGS, 0, 0, 10, 10, parent, nullptr,
      GetModuleHandleW(nullptr), this);
  if (hwnd) {
    SetWindowLongPtrW(hwnd, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(this));
  }
  return hwnd;
}

void KotvWinChrome::DestroyAll() {
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
  ShowPanel(center_play_, center_visible_, (W - center_s) / 2, (H - center_s) / 2,
            center_s, center_s);
}

void KotvWinChrome::PaintDark(HWND hwnd, HDC hdc, const RECT& rc,
                              const std::wstring& title,
                              const std::vector<std::wstring>* lines,
                              int selected) {
  HBRUSH bg = CreateSolidBrush(RGB(18, 18, 22));
  FillRect(hdc, &rc, bg);
  DeleteObject(bg);

  SetBkMode(hdc, TRANSPARENT);
  SetTextColor(hdc, RGB(235, 235, 240));
  HFONT font = CreateFontW(18, 0, 0, 0, FW_SEMIBOLD, FALSE, FALSE, FALSE,
                           DEFAULT_CHARSET, OUT_DEFAULT_PRECIS,
                           CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY,
                           DEFAULT_PITCH | FF_SWISS, L"Segoe UI");
  HFONT old = (HFONT)SelectObject(hdc, font);

  if (!title.empty()) {
    RECT tr = rc;
    tr.left += 16;
    tr.top += 12;
    tr.right -= 16;
    DrawTextW(hdc, title.c_str(), -1, &tr,
              DT_LEFT | DT_TOP | DT_END_ELLIPSIS | DT_SINGLELINE);
  }

  if (hwnd == bottom_.hwnd) {
    // 进度条
    RECT bar = {rc.left + 16, rc.bottom - 28, rc.right - 16, rc.bottom - 20};
    HBRUSH track = CreateSolidBrush(RGB(60, 60, 70));
    FillRect(hdc, &bar, track);
    DeleteObject(track);
    int fill = static_cast<int>((bar.right - bar.left) * std::clamp(progress_, 0.0, 1.0));
    RECT fill_rc = {bar.left, bar.top, bar.left + fill, bar.bottom};
    HBRUSH fill_br = CreateSolidBrush(RGB(80, 160, 255));
    FillRect(hdc, &fill_rc, fill_br);
    DeleteObject(fill_br);
    if (!bottom_text_.empty()) {
      RECT tr = rc;
      tr.left += 16;
      tr.top += 14;
      DrawTextW(hdc, bottom_text_.c_str(), -1, &tr,
                DT_LEFT | DT_TOP | DT_END_ELLIPSIS | DT_SINGLELINE);
    }
  }

  if (hwnd == center_play_.hwnd) {
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
      } else if (hwnd == bottom_.hwnd) {
        title = L"";
      } else if (hwnd == channel_info_.hwnd) {
        title = L"";
      }
      PaintDark(hwnd, hdc, rc, title, lines, selected);
      EndPaint(hwnd, &ps);
      return 0;
    }
    case WM_LBUTTONUP: {
      int y = GET_Y_LPARAM(lp);
      if (hwnd == center_play_.hwnd) {
        Emit({{EncodableValue("type"), EncodableValue("togglePlay")}});
        return 0;
      }
      if (hwnd == bottom_.hwnd) {
        RECT rc;
        GetClientRect(hwnd, &rc);
        // 点进度条 seek
        if (y > rc.bottom - 36) {
          double x = GET_X_LPARAM(lp);
          double p = (x - 16) / std::max(1.0, static_cast<double>(rc.right - 32));
          p = std::clamp(p, 0.0, 1.0);
          Emit({{EncodableValue("type"), EncodableValue("seekFraction")},
                {EncodableValue("value"), EncodableValue(p)}});
        } else {
          Emit({{EncodableValue("type"), EncodableValue("togglePlay")}});
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
      if (hwnd == top_.hwnd) {
        Emit({{EncodableValue("type"), EncodableValue("back")}});
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

void KotvWinChrome::HandleMethod(
    const std::string& method, const EncodableMap* args,
    std::function<void(EncodableValue)> success,
    std::function<void(const std::string&, const std::string&)> error) {
  (void)error;
  if (method == "isAvailable") {
    // 仅 Win7 包需要原生壳；运行时仍可探测。
    success(EncodableValue(true));
    return;
  }
  if (method == "setEnabled") {
    enabled_ = ArgBool(args, "enabled");
    if (enabled_) {
      EnsureClasses();
      if (!top_.hwnd) top_.hwnd = CreatePanel(L"KotvWinChromePanel", 0, L"top");
      if (!bottom_.hwnd)
        bottom_.hwnd = CreatePanel(L"KotvWinChromePanel", 0, L"bottom");
      if (!episodes_.hwnd)
        episodes_.hwnd = CreatePanel(L"KotvWinChromePanel", 0, L"episodes");
      if (!live_left_.hwnd)
        live_left_.hwnd = CreatePanel(L"KotvWinChromePanel", 0, L"liveLeft");
      if (!live_right_.hwnd)
        live_right_.hwnd = CreatePanel(L"KotvWinChromePanel", 0, L"liveRight");
      if (!channel_info_.hwnd)
        channel_info_.hwnd =
            CreatePanel(L"KotvWinChromePanel", 0, L"channel");
      if (!center_play_.hwnd)
        center_play_.hwnd =
            CreatePanel(L"KotvWinChromePanel", 0, L"center");
      Layout();
    } else {
      DestroyAll();
    }
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
      if (args->count(EncodableValue("playing")))
        playing_ = ArgBool(args, "playing", true);

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
