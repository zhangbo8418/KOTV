#pragma once

#include <functional>
#include <map>
#include <string>
#include <variant>
#include <vector>
#include <windows.h>

// Win7 播控壳（GDI+）：无 Flutter 依赖，可供 runner 插件与 tools/win7_mpv_chrome 共用。
class Win7ChromeShell {
 public:
  using ChromeValue = std::variant<std::monostate, bool, int64_t, double, std::string>;
  using ChromeMap = std::map<std::string, ChromeValue>;
  using EventFn = std::function<void(ChromeMap)>;

  enum class RowIcon {
    None,
    Tune,
    Equalizer,
    Repeat,
    Sunny,
    GraphicEq,
    SkipNext,
    Playlist,
    Search,
    Bedtime,
    Cast,
    Pip,
    Sparkle,
    Refresh,
    Favorite,
    Layers,
    Info,
    FullscreenExit,
    Subtitles,
  };

  struct LineItem {
    std::string id;
    std::wstring label;
    std::wstring trailing;
    bool toggle = false;
    bool on = false;
    bool chevron = false;
    bool slider = false;
    bool hold_preview = false;
    RowIcon icon = RowIcon::None;
    double slider_min = 0;
    double slider_max = 100;
    double slider_value = 0;
  };

  Win7ChromeShell();
  ~Win7ChromeShell();

  void Attach(HWND host);
  HWND HostHwnd() const { return host_hwnd_; }
  void SetEventSink(EventFn fn);
  void SetEnabled(bool enabled);
  bool enabled() const { return enabled_; }

  // 返回 true 表示几何/显隐/mode 变化，调用方应 Layout；仅进度/标签等则 Invalidate 即可。
  bool ApplyUpdate(const ChromeMap& args);
  void ApplyDanmaku(const ChromeMap& args);
  void ApplySheet(const ChromeMap& args);
  void HideSheet();
  void Layout();
  void InvalidateChrome();

  void LoadDemoVodFullscreen();
  void LoadDemoVodInline();
  void LoadDemoLive();
  void LoadDemoLiveChannelBar();
  void LoadDemoLiveRight();

 private:
  struct Panel {
    HWND hwnd = nullptr;
    int x = 0;
    int y = 0;
    int w = 0;
    int h = 0;
    bool shown = false;
  };

  struct DanmakuItem {
    double time = 0;
    std::wstring content;
    int mode = 1;
    int color = 0xFFFFFF;
    int size = 25;
  };

  HWND RootHwnd() const;
  void EnsureClasses();
  void DestroyAll();
  enum class HudKind { None, HoldSpeed, Volume, Seek, Ep };

  void LayoutDanmaku();
  void LayoutModal();
  void LayoutGesture();
  void LayoutHud();
  void SetGestureHud(HudKind kind, const std::wstring& text, bool auto_hide = false);
  void ClearGestureHud();
  double EstimatedTotalSec() const;
  static std::wstring FormatHudClock(double sec);
  void ShowPanel(Panel& p, bool show, int x, int y, int w, int h);
  HWND CreateChildPanel(const wchar_t* title);
  HWND CreateLayeredPopup(const wchar_t* class_name);
  // Win7：WS_EX_LAYERED 仅顶层有效，子窗设 LAYERED 会导致不绘制/闪。播控子窗必须清掉。
  static void ClearChildLayered(HWND hwnd);
  void ApplyRoundRegion(HWND hwnd, int w, int h, int radius);
  void SubclassHost(bool enable);
  void SyncModalToHost(bool invalidate);
  static LRESULT CALLBACK WndProc(HWND, UINT, WPARAM, LPARAM);
  static LRESULT CALLBACK DanmakuWndProc(HWND, UINT, WPARAM, LPARAM);
  static LRESULT CALLBACK ModalWndProc(HWND, UINT, WPARAM, LPARAM);
  static LRESULT CALLBACK GestureWndProc(HWND, UINT, WPARAM, LPARAM);
  static LRESULT CALLBACK HostSubclassProc(HWND, UINT, WPARAM, LPARAM, UINT_PTR, DWORD_PTR);
  static LRESULT CALLBACK RootSubclassProc(HWND, UINT, WPARAM, LPARAM, UINT_PTR, DWORD_PTR);
  LRESULT OnMessage(HWND, UINT, WPARAM, LPARAM);
  LRESULT OnDanmakuMessage(HWND, UINT, WPARAM, LPARAM);
  LRESULT OnModalMessage(HWND, UINT, WPARAM, LPARAM);
  LRESULT OnGestureMessage(HWND, UINT, WPARAM, LPARAM);
  void Emit(ChromeMap map);
  void EmitPointerHold(bool on);
  void PaintPanel(HWND hwnd, HDC hdc, const RECT& rc);
  void PaintTop(HDC hdc, const RECT& rc);
  void PaintBottom(HDC hdc, const RECT& rc);
  void PaintBottomInline(HDC hdc, const RECT& rc);
  void PaintBottomFullscreen(HDC hdc, const RECT& rc);
  bool ResolveAnchor(int* x, int* y, int* w, int* h) const;
  bool ResolveSurface(int* x, int* y, int* w, int* h) const;
  double ViewDpiScale() const;
  void RaiseChromeZ();
  void PaintEpisodes(HDC hdc, const RECT& rc);
  void PaintLiveLeft(HDC hdc, const RECT& rc);
  void PaintLiveRight(HDC hdc, const RECT& rc);
  void PaintChannelInfo(HDC hdc, const RECT& rc);
  void PaintCenter(HDC hdc, const RECT& rc);
  void PaintGestureHud(HDC hdc, const RECT& rc);
  void PaintModal(HDC hdc, const RECT& rc);
  void PaintEqSheet(HDC hdc, const RECT& card);
  void PaintListSheet(HDC hdc, const RECT& card, bool light);
  void PaintDanmaku(HWND hwnd);
  void CloseSheet(bool emit_close = true);
  void ApplyLocalAction(const std::string& type, double value = 0);
  void EmitOffsets();
  void OpenSheet(const std::string& kind, const std::wstring& title,
                 std::vector<LineItem> items);
  // 选择列表（倍速/解码/休眠/渲染/全屏方式等常量项）收拢入口
  void OpenChoiceSheet(const std::string& kind, const std::wstring& title,
                       const std::vector<std::pair<std::string, std::wstring>>& options,
                       const std::string& selected_id = {});
  void OpenMoreSheet();
  void OpenFullscreenKindSheet();
  void OpenDanmakuSheet();
  void OpenVideoEqSheet();
  void OpenAudioFxSheet();
  void HandleMoreId(const std::string& id);
  // 壳内自绘子 sheet（勿再让 Dart 开一层）；轨/播放器/弹幕源/播放信息由 Dart showSheet
  bool OpensNativeChildSheet(const std::string& id) const;
  bool IsEqSheet() const;
  bool HandleEqClick(int x, int y, bool down, bool up);
  void ResetVideoEqSliders();
  std::string AspectKey() const;
  std::wstring AspectBadge() const;
  std::string DecodeKey() const;
  std::wstring DecodeBadge() const;
  int ModalHeaderH(bool light) const;
  int ModalRowH(bool light) const;
  RECT ModalCardRect(const RECT& full) const;
  int EstimateSheetContentH() const;

  struct HitTarget {
    std::string id;
    RECT rc{};
  };
  void BeginHits(std::vector<HitTarget>* sink);
  void AddHit(const char* id, const RECT& rc);
  const HitTarget* HitTest(const std::vector<HitTarget>& hits, int x, int y) const;
  bool DispatchHit(HWND hwnd, int x, int y);

  HWND host_hwnd_ = nullptr;
  EventFn event_fn_;
  ULONG_PTR gdiplus_token_ = 0;
  bool classes_ready_ = false;
  bool enabled_ = false;
  bool host_subclassed_ = false;
  bool root_subclassed_ = false;
  HWND root_hwnd_ = nullptr;

  Panel top_;
  Panel bottom_;
  Panel episodes_;
  Panel live_left_;
  Panel live_right_;
  Panel channel_info_;
  Panel center_play_;
  Panel gesture_;
  Panel hud_;
  HWND danmaku_hwnd_ = nullptr;
  HWND modal_hwnd_ = nullptr;
  UINT_PTR danmaku_timer_ = 0;
  UINT_PTR hold_speed_timer_ = 0;
  UINT_PTR episodes_close_timer_ = 0;
  UINT_PTR hud_hide_timer_ = 0;

  std::string mode_;
  std::wstring title_;
  std::wstring subtitle_;
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

  double anchor_screen_l_ = 0;
  double anchor_screen_t_ = 0;
  double anchor_screen_w_ = 0;
  double anchor_screen_h_ = 0;
  bool anchor_valid_ = false;
  double surface_screen_l_ = 0;
  double surface_screen_t_ = 0;
  double surface_screen_w_ = 0;
  double surface_screen_h_ = 0;
  bool surface_valid_ = false;
  double volume_ = 100;
  bool volume_expanded_ = false;
  bool show_direct_ = false;
  bool direct_on_ = false;
  bool mini_active_ = false;

  std::vector<std::wstring> groups_;
  int group_selected_ = -1;
  std::vector<std::wstring> channels_;
  int channel_selected_ = -1;
  std::vector<std::wstring> epg_days_;
  int epg_day_selected_ = 0;
  std::vector<std::wstring> epg_programs_;
  int epg_program_selected_ = -1;
  bool epg_open_ = true;

  std::vector<LineItem> live_right_items_;
  std::vector<LineItem> more_items_;
  std::vector<LineItem> sheet_items_;
  std::wstring sheet_title_;
  std::wstring sheet_subtitle_;
  std::string sheet_kind_;
  int sheet_selected_ = 0;
  int sheet_scroll_ = 0;
  RECT modal_card_{};
  std::vector<HitTarget> modal_hits_;

  // videoEq / audioFx 专用状态
  std::string eq_preset_ = "off";
  double video_brightness_ = 0;
  double video_contrast_ = 0;
  double video_saturation_ = 0;
  double video_sharpness_ = 0;
  double video_temperature_ = 0;
  double audio_dialogue_ = 0;
  double audio_balance_ = 0;
  double audio_offset_ms_ = 0;

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
  double buffered_ = 0;
  double position_sec_ = 0;
  double rate_ = 1.0;
  int opening_sec_ = 0;
  int ending_sec_ = 0;
  int aspect_idx_ = 0;
  int decode_idx_ = 0;
  bool loop_skip_ = true;
  bool ambient_on_ = false;
  bool repeat_one_ = false;
  bool stable_volume_ = false;
  bool danmaku_bold_ = false;
  bool danmaku_show_positioned_ = true;
  bool danmaku_show_special_ = true;
  std::vector<std::string> actions_;
  std::vector<HitTarget> top_hits_;
  std::vector<HitTarget> bottom_hits_;
  std::vector<HitTarget> center_hits_;
  std::vector<HitTarget>* hit_sink_ = nullptr;
  std::string drag_id_;

  bool pointer_hold_ = false;
  bool sheet_open_hold_ = false;

  enum class GestureMode { None, Pending, Seek, Volume, HoldSpeed, Ep };
  GestureMode ges_mode_ = GestureMode::None;
  HudKind hud_kind_ = HudKind::None;
  std::wstring hud_text_;
  POINT ges_down_{};
  DWORD ges_down_tick_ = 0;
  bool ges_moved_ = false;
  double ges_origin_progress_ = 0;
  double ges_origin_volume_ = 0;
  int ges_client_w_ = 0;
  double hold_speed_rate_ = 2.0;

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
  int danmaku_max_on_screen_ = 80;
  double danmaku_scroll_area_ = 1.0;
  int danmaku_source_idx_ = 0;
  std::string render_mode_ = "surface";
};
