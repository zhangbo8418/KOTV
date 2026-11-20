#pragma once

#include <flutter/encodable_value.h>
#include <flutter/plugin_registrar_windows.h>

#include <functional>
#include <memory>
#include <string>
#include <vector>
#include <windows.h>

// Win7：库存引擎下子 HWND 盖住 Flutter，用原生套壳承接全屏/直播菜单。
// Win8+ DComp 路径不启用（Dart 侧按 OS 分支）。
class KotvWinChrome {
 public:
  using EncodableMap = flutter::EncodableMap;
  using EncodableValue = flutter::EncodableValue;
  using EventFn = std::function<void(EncodableMap)>;

  explicit KotvWinChrome(flutter::PluginRegistrarWindows* registrar);
  ~KotvWinChrome();

  void SetEventSink(EventFn fn);
  void HandleMethod(const std::string& method, const EncodableMap* args,
                    std::function<void(EncodableValue)> success,
                    std::function<void(const std::string&, const std::string&)> error);

 private:
  struct Panel {
    HWND hwnd = nullptr;
    std::wstring class_name;
  };

  HWND FlutterHwnd() const;
  void EnsureClasses();
  void DestroyAll();
  void Layout();
  void ShowPanel(Panel& p, bool show, int x, int y, int w, int h);
  HWND CreatePanel(const wchar_t* class_name, DWORD ex, const wchar_t* title);
  static LRESULT CALLBACK WndProc(HWND, UINT, WPARAM, LPARAM);
  LRESULT OnMessage(HWND, UINT, WPARAM, LPARAM);
  void Emit(EncodableMap map);
  void PaintDark(HWND hwnd, HDC hdc, const RECT& rc, const std::wstring& title,
                 const std::vector<std::wstring>* lines, int selected);

  flutter::PluginRegistrarWindows* registrar_;
  EventFn event_fn_;
  bool classes_ready_ = false;
  bool enabled_ = false;

  Panel top_;
  Panel bottom_;
  Panel episodes_;
  Panel live_left_;
  Panel live_right_;
  Panel channel_info_;
  Panel center_play_;

  std::wstring title_;
  std::wstring subtitle_;
  std::wstring bottom_text_;
  std::wstring channel_text_;
  std::vector<std::wstring> episode_lines_;
  int episode_selected_ = -1;
  std::vector<std::wstring> live_left_lines_;
  int live_left_selected_ = -1;
  std::vector<std::wstring> live_right_lines_;
  bool top_visible_ = false;
  bool bottom_visible_ = false;
  bool episodes_visible_ = false;
  bool live_left_visible_ = false;
  bool live_right_visible_ = false;
  bool channel_visible_ = false;
  bool center_visible_ = false;
  bool playing_ = true;
  double progress_ = 0;  // 0..1
};

void KotvWinChromeRegisterWithRegistrar(FlutterDesktopPluginRegistrarRef registrar);
