#pragma once

#include <flutter/encodable_value.h>
#include <flutter/plugin_registrar_windows.h>

#include <functional>
#include <memory>
#include <string>
#include <vector>
#include <windows.h>

// Win7：原生壳仿现网 Flutter 播控主路径（顶底栏/更多/弹幕设置/选播放器、直播左栏EPG/右设置/频道条）。
// Win8+ DComp 不启用。
class KotvWinChrome {
 public:
  using EncodableMap = flutter::EncodableMap;
  using EncodableValue = flutter::EncodableValue;
  using EventFn = std::function<void(EncodableMap)>;

  struct LineItem {
    std::string id;
    std::wstring label;
    std::wstring trailing;
    bool toggle = false;
    bool on = false;
    bool chevron = false;
    bool slider = false;
    double slider_min = 0;
    double slider_max = 100;
    double slider_value = 0;
  };

  explicit KotvWinChrome(flutter::PluginRegistrarWindows* registrar);
  ~KotvWinChrome();

  void SetEventSink(EventFn fn);
  void HandleMethod(const std::string& method, const EncodableMap* args,
                    std::function<void(EncodableValue)> success,
                    std::function<void(const std::string&, const std::string&)> error);

 private:
  struct Panel {
    HWND hwnd = nullptr;
  };

  struct DanmakuItem {
    double time = 0;
    std::wstring content;
    int mode = 1;
    int color = 0xFFFFFF;
    int size = 25;
  };

  HWND FlutterHwnd() const;
  HWND RootHwnd() const;
  void EnsureClasses();
  void DestroyAll();
  void Layout();
  void LayoutDanmaku();
  void LayoutModal();
  void ShowPanel(Panel& p, bool show, int x, int y, int w, int h);
  HWND CreateChildPanel(const wchar_t* title);
  HWND CreateLayeredPopup(const wchar_t* class_name);
  void ApplyRoundRegion(HWND hwnd, int w, int h, int radius);
  static LRESULT CALLBACK WndProc(HWND, UINT, WPARAM, LPARAM);
  static LRESULT CALLBACK DanmakuWndProc(HWND, UINT, WPARAM, LPARAM);
  static LRESULT CALLBACK ModalWndProc(HWND, UINT, WPARAM, LPARAM);
  LRESULT OnMessage(HWND, UINT, WPARAM, LPARAM);
  LRESULT OnDanmakuMessage(HWND, UINT, WPARAM, LPARAM);
  LRESULT OnModalMessage(HWND, UINT, WPARAM, LPARAM);
  void Emit(EncodableMap map);
  void PaintPanel(HWND hwnd, HDC hdc, const RECT& rc);
  void PaintTop(HDC hdc, const RECT& rc);
  void PaintBottom(HDC hdc, const RECT& rc);
  void PaintEpisodes(HDC hdc, const RECT& rc);
  void PaintLiveLeft(HDC hdc, const RECT& rc);
  void PaintLiveRight(HDC hdc, const RECT& rc);
  void PaintChannelInfo(HDC hdc, const RECT& rc);
  void PaintCenter(HDC hdc, const RECT& rc);
  void PaintModal(HDC hdc, const RECT& rc);
  void PaintDanmaku(HWND hwnd);
  void IngestDanmaku(const EncodableMap* args);
  void IngestUpdate(const EncodableMap* args);
  void IngestSheet(const EncodableMap* args);
  void CloseSheet();

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
  HWND danmaku_hwnd_ = nullptr;
  HWND modal_hwnd_ = nullptr;
  UINT_PTR danmaku_timer_ = 0;

  std::wstring title_;
  std::wstring subtitle_;  // 分辨率等
  std::wstring clock_;
  std::wstring ends_at_;
  std::wstring pos_label_;
  std::wstring dur_label_;
  std::wstring channel_no_;
  std::wstring channel_name_;
  std::wstring channel_prog_;
  std::wstring channel_ticker_;
  std::vector<std::wstring> episode_lines_;
  int episode_selected_ = -1;

  std::vector<std::wstring> groups_;
  int group_selected_ = -1;
  std::vector<std::wstring> channels_;
  int channel_selected_ = -1;
  std::vector<std::wstring> epg_days_;
  int epg_day_selected_ = 0;
  std::vector<std::wstring> epg_programs_;
  int epg_program_selected_ = -1;

  std::vector<LineItem> live_right_items_;
  std::vector<LineItem> more_items_;
  std::vector<LineItem> sheet_items_;
  std::wstring sheet_title_;
  std::wstring sheet_subtitle_;
  std::string sheet_kind_;  // more | danmaku | player | ""
  int sheet_selected_ = 0;

  bool top_visible_ = false;
  bool bottom_visible_ = false;
  bool episodes_visible_ = false;
  bool live_left_visible_ = false;
  bool live_right_visible_ = false;
  bool channel_visible_ = false;
  bool center_visible_ = false;
  bool playing_ = true;
  bool buffering_ = false;
  double progress_ = 0;
  double position_sec_ = 0;
  double rate_ = 1.0;
  std::vector<std::string> actions_;

  bool danmaku_enabled_ = false;
  std::vector<DanmakuItem> danmaku_items_;
  double danmaku_font_ = 18;
  double danmaku_opacity_ = 0.85;
  int danmaku_duration_ms_ = 8000;
  int danmaku_fixed_ms_ = 5000;
  int danmaku_rows_ = 6;
  bool danmaku_show_scroll_ = true;
  bool danmaku_show_top_ = true;
  bool danmaku_show_bottom_ = true;
  bool danmaku_show_reverse_ = true;
};

void KotvWinChromeRegisterWithRegistrar(FlutterDesktopPluginRegistrarRef registrar);
