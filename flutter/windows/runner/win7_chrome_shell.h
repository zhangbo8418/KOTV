#ifndef RUNNER_WIN7_CHROME_SHELL_H_
#define RUNNER_WIN7_CHROME_SHELL_H_

#include <windows.h>

#include <cstdint>
#include <functional>
#include <map>
#include <memory>
#include <string>
#include <variant>
#include <vector>

#include "win7_chrome_canvas.h"

// Win7 进程内原生播控壳。样式、数值和交互以 Flutter 播控为准
// （VodInlineControls / VodFullscreenChrome / 直播面板 / LiveCatchupChrome / MiniHoverShell）。
// 各面板是宿主根窗的 owned 分层 popup（逐像素 alpha），手势层是压在它们之下、近乎全透明的同类 popup，
// 画面（mpv 子窗或 FVP 纹理）从下面透出；画面区指针事件原样转给 Dart，由 Flutter 页面复用自己的手势逻辑。
class Win7ChromeShell {
 public:
  using ChromeValue = std::variant<std::monostate, bool, int64_t, double, std::string>;
  using ChromeMap = std::map<std::string, ChromeValue>;
  using EventFn = std::function<void(ChromeMap)>;

  // Dart 行模型：id|label|trailing|toggle|on|chevron|slider|min|max|value|icon|kind|selected|sub|divisions
  struct LineItem {
    std::string id;
    std::wstring label;
    std::wstring trailing;
    std::wstring sub;
    std::string icon;
    std::string kind;
    bool toggle = false;
    bool on = false;
    bool chevron = false;
    bool slider = false;
    bool selected = false;
    double slider_min = 0;
    double slider_max = 100;
    double slider_value = 0;
    int divisions = 0;
  };

  Win7ChromeShell();
  ~Win7ChromeShell();

  void Attach(HWND host);
  HWND HostHwnd() const { return host_hwnd_; }
  void SetEventSink(EventFn fn) { event_fn_ = std::move(fn); }
  void SetEnabled(bool enabled);
  bool enabled() const { return enabled_; }

  bool ApplyUpdate(const ChromeMap& args);
  void ApplyDanmaku(const ChromeMap& args);
  void ApplySheet(const ChromeMap& args);
  void HideSheet();
  void Layout();
  void InvalidateChrome();

 private:
  enum PanelId {
    kTop,
    kBottom,
    kEpisodes,
    kLiveLeft,
    kLiveRight,
    kChannel,
    kCenter,
    kPill,
    kDebug,
    kHud,
    kZap,
    kBuffer,
    kPeek,
    kSheet,
    kPopup,
    kPanelCount
  };

  struct Hit {
    std::string id;
    RECT rc{};
    int index = -1;
  };

  struct Panel {
    HWND hwnd = nullptr;
    RECT rc{};  // 宿主客户区像素
    bool shown = false;
    bool dirty = true;
    bool click_through = false;
    std::vector<Hit> hits;
    std::unique_ptr<kotv_chrome::Canvas> canvas;
  };

  struct DanmakuItem {
    double time = 0;
    std::wstring content;
    int mode = 1;
    int color = 0xFFFFFF;
    int size = 25;
    int pool = 0;
    double x = 0;
    double y = 0;
    int duration_ms = 0;
    // DanmakuItem.sizeScale
    double SizeScale() const { return size <= 18 ? 12.0 / 14.0 : (size >= 36 ? 18.0 / 14.0 : 1.0); }
  };
  // 在屏弹幕（_Flying）：入轨时定下轨道与时长，之后只按时间推进。
  struct DanmakuFlying {
    size_t idx = 0;
    double activated = 0;
    int lane = 0;
    int duration_ms = 0;
    double text_w = 0;  // 物理像素
  };

  enum class HudKind { None, Text, Side, Seek };

  // ---- 尺寸（物理像素）----
  void UpdateMetrics();
  int P(double v) const;  // 逻辑像素
  int G(double v) const;  // × LayoutScale.grow
  int L(double v) const;  // × LayoutScale.layoutOf
  float F(double v) const;  // 字号 × textScale
  float FL(double v) const;  // 药丸字号 × layoutOf
  bool Land() const { return land_; }

  // ---- 窗口 ----
  HWND RootHwnd() const;
  void EnsureWindows();
  void DestroyAll();
  void SubclassHost(bool enable);
  void ShowPanel(PanelId id, bool show, const RECT& rc);
  void HideAllPanels();
  void Render(PanelId id);
  void RenderDirty();
  void ScheduleRender();
  void MarkDirty(PanelId id);
  bool HostRectFromLogical(double l, double t, double w, double h, RECT* out) const;
  RECT HostClient() const;
  RECT VideoArea() const;
  // 详情内嵌：顶栏下内容区（宿主坐标）。页面滚动时画面和播控都要按它裁掉。
  bool InlineClip(RECT* out) const;
  void LayoutGesture();
  void LayoutDanmaku();
  void LayoutHud();
  void LayoutSheet();
  void UpdateDanmakuTimer();

  // ---- 面板尺寸 ----
  int InlineBarH(int w) const;
  int FullscreenTopH() const;
  int FullscreenBottomH() const;
  int CatchupBarH(int w) const;
  int LiveLeftW(int host_w) const;
  int LiveRightW(int host_w) const;
  int ChannelBarH() const;

  // ---- 绘制 ----
  void Paint(PanelId id, kotv_chrome::Canvas& cv, std::vector<Hit>& hits);
  void PaintTop(kotv_chrome::Canvas& cv, std::vector<Hit>& hits);
  void PaintInlineBar(kotv_chrome::Canvas& cv, std::vector<Hit>& hits, bool mini);
  void PaintFullscreenBottom(kotv_chrome::Canvas& cv, std::vector<Hit>& hits);
  void PaintCatchupBar(kotv_chrome::Canvas& cv, std::vector<Hit>& hits, bool mini);
  void PaintEpisodes(kotv_chrome::Canvas& cv, std::vector<Hit>& hits);
  void PaintLiveLeft(kotv_chrome::Canvas& cv, std::vector<Hit>& hits);
  void PaintLiveRight(kotv_chrome::Canvas& cv, std::vector<Hit>& hits);
  void PaintChannel(kotv_chrome::Canvas& cv);
  void PaintCenter(kotv_chrome::Canvas& cv, std::vector<Hit>& hits);
  void PaintPill(kotv_chrome::Canvas& cv, std::vector<Hit>& hits);
  void PaintDebug(kotv_chrome::Canvas& cv);
  void PaintHud(kotv_chrome::Canvas& cv);
  void PaintZap(kotv_chrome::Canvas& cv);
  void PaintBuffer(kotv_chrome::Canvas& cv);
  void PaintPeek(kotv_chrome::Canvas& cv);
  void PaintLogo(kotv_chrome::Canvas& cv, const RECT& rc, const std::string& key, const std::wstring& name,
                 const std::wstring& letter_hint);
  void PaintSheet(kotv_chrome::Canvas& cv, std::vector<Hit>& hits);
  void PaintPopup(kotv_chrome::Canvas& cv, std::vector<Hit>& hits);
  void PaintDanmaku();
  void ActivateDanmaku(double media_sec, double view_w, float fs, int weight, kotv_chrome::Canvas& cv);
  bool DanmakuAllowed(const DanmakuItem& d) const;
  int PaintVolume(kotv_chrome::Canvas& cv, std::vector<Hit>& hits, int right, int cy, int box,
                  bool compact, double slider_w);
  void PaintSlider(kotv_chrome::Canvas& cv, const RECT& area, double frac, double secondary,
                   int track_h, int thumb_r, int inset, kotv_chrome::Argb active,
                   kotv_chrome::Argb inactive, kotv_chrome::Argb secondary_c, kotv_chrome::Argb thumb);
  int PaintIconAct(kotv_chrome::Canvas& cv, std::vector<Hit>& hits, const char* id, int x, int y,
                   int box, uint32_t cp, const std::wstring& badge);
  int PaintTextAct(kotv_chrome::Canvas& cv, std::vector<Hit>& hits, const char* id, int x, int cy,
                   const std::wstring& label, float px, int pad);
  void PaintAppPill(kotv_chrome::Canvas& cv, const RECT& rc, const std::wstring& label,
                    const std::wstring& suffix, double font, bool selected, bool marquee = false);
  int MarqueeText(kotv_chrome::Canvas& cv, const RECT& rc, const std::wstring& s, kotv_chrome::Argb c, float px,
                  int weight, UINT fmt, bool active);
  void UpdateMarqueeTimer();
  int SheetLayout(kotv_chrome::Canvas* cv, std::vector<Hit>* hits, const RECT& card, int scroll);

  // ---- 输入 ----
  static LRESULT CALLBACK PanelWndProc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp);
  static LRESULT CALLBACK GestureWndProc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp);
  static LRESULT CALLBACK MsgWndProc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp);
  static LRESULT CALLBACK DanmakuWndProc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp);
  static LRESULT CALLBACK HostSubclassProc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp, UINT_PTR id,
                                           DWORD_PTR data);
  static LRESULT CALLBACK RootSubclassProc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp, UINT_PTR id,
                                           DWORD_PTR data);
  LRESULT OnPanel(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp);
  LRESULT OnGesture(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp);
  void OnTimer(UINT_PTR id);
  PanelId PanelOf(HWND hwnd) const;
  const Hit* HitAt(PanelId id, int x, int y) const;
  void OnHitDown(PanelId pid, const Hit& hit, int x, int y);
  void OnHitDrag(PanelId pid, const Hit& hit, int x, int y);
  void OnHitUp(PanelId pid, const Hit& hit, int x, int y, bool inside);
  void OnSheetTap(const Hit& hit, int x);
  void OnWheel(PanelId pid, int delta, int x, int y);
  bool HandleKey(UINT msg, WPARAM wp, LPARAM lp);
  bool RouteWheel(WPARAM wp, LPARAM lp);
  void EmitPointer(const char* phase, int host_x, int host_y, double dx = 0, double dy = 0,
                   bool shift = false);
  void Emit(ChromeMap map);
  void EmitPointerHold(bool on);
  void EmitSlider(const std::string& id, double value, bool commit);

  // ---- 行为 ----
  void OpenSheet(const std::string& kind, const std::wstring& title, const std::wstring& subtitle,
                 std::vector<LineItem> items);
  void CloseSheet(bool emit);
  void OpenFullscreenPopup(const RECT& anchor_host);
  void ClosePopup();
  void SetVolumeExpanded(bool on);
  void SetHud(HudKind kind, const std::wstring& text, uint32_t icon, double size, bool ui);
  double TotalSec() const;
  bool IsMini() const { return mode_ == "mini"; }
  bool IsLive() const { return mode_ == "live" || mini_kind_ == "live"; }

  // ---- 状态 ----
  HWND host_hwnd_ = nullptr;
  HWND subclassed_root_ = nullptr;
  HWND msg_hwnd_ = nullptr;
  HWND gesture_hwnd_ = nullptr;
  HWND danmaku_hwnd_ = nullptr;
  bool host_subclassed_ = false;
  bool enabled_ = false;
  bool suspended_ = false;
  bool render_posted_ = false;
  EventFn event_fn_;
  ULONG_PTR gdiplus_token_ = 0;
  Panel panels_[kPanelCount];
  std::unique_ptr<kotv_chrome::Canvas> danmaku_canvas_;

  // 缩放
  double dpr_ = 1.0;
  double dpr_override_ = 0;
  double scale_ = 1.0;
  double grow_ = 1.0;
  double text_scale_ = 1.0;
  double layout_of_ = 1.0;
  bool land_ = false;

  // 调色板（KotvPalette 推送）
  kotv_chrome::Argb pal_primary_ = 0xFFCF4274;
  kotv_chrome::Argb pal_fg_ = 0xFFFFFFFF;
  kotv_chrome::Argb pal_muted_ = 0xB3FFFFFF;
  kotv_chrome::Argb pal_pill_bg_ = 0xA6121218;
  kotv_chrome::Argb pal_pill_border_ = 0x994A4855;
  kotv_chrome::Argb pal_dialog_bg_ = 0xE0121218;
  kotv_chrome::Argb pal_selected_ = 0xD9C73C62;

  // 模式与几何
  std::string mode_;       // vod_inline | vod | live | mini
  std::string mini_kind_;  // vod | live
  bool anchor_valid_ = false;
  double anchor_l_ = 0, anchor_t_ = 0, anchor_w_ = 0, anchor_h_ = 0;
  bool surface_valid_ = false;
  double clip_l_ = 0, clip_t_ = 0, clip_w_ = 0, clip_h_ = 0;
  bool clip_valid_ = false;
  double surface_l_ = 0, surface_t_ = 0, surface_w_ = 0, surface_h_ = 0;

  // 点播
  std::wstring title_;
  std::wstring resolution_;
  bool playing_ = false;
  bool buffering_ = false;
  double position_sec_ = 0;
  DWORD position_tick_ = 0;
  double duration_sec_ = 0;
  double buffered_sec_ = 0;
  bool bounded_ = true;
  double rate_ = 1.0;
  double volume_ = 100;
  int opening_sec_ = 0;
  int ending_sec_ = 0;
  std::wstring speed_badge_;
  std::wstring aspect_badge_;
  std::wstring decode_badge_;
  std::wstring player_badge_;
  bool show_direct_ = false;
  bool direct_on_ = false;
  bool show_disc_ = false;
  bool show_speed_ = true;
  bool show_player_ = true;
  bool has_cast_ = false;
  bool has_mini_ = false;
  bool top_visible_ = false;
  bool bottom_visible_ = false;
  bool center_visible_ = false;
  bool episodes_visible_ = false;
  bool debug_hud_on_ = false;
  std::wstring debug_text_;
  bool gestures_ = true;
  std::vector<std::wstring> episodes_;
  int episode_selected_ = -1;
  int episode_scroll_ = 0;
  int episode_pinned_ = -2;
  std::vector<LineItem> more_items_;

  // 直播
  std::vector<LineItem> groups_;
  std::vector<LineItem> channels_;
  std::vector<LineItem> programs_;
  std::vector<std::wstring> epg_days_;
  std::vector<LineItem> live_right_items_;
  int group_selected_ = -1;
  int channel_selected_ = -1;
  int epg_day_selected_ = 0;
  int program_selected_ = -1;
  bool epg_open_ = false;
  bool live_left_visible_ = false;
  bool live_right_visible_ = false;
  bool channel_visible_ = false;
  int group_scroll_ = 0, channel_scroll_ = 0, program_scroll_ = 0, right_scroll_ = 0, day_scroll_ = 0;
  int group_pinned_ = -2, channel_pinned_ = -2, program_pinned_ = -2, day_pinned_ = -2;
  int channel_digits_ = 3;
  std::wstring channel_no_;
  std::wstring channel_name_;
  std::wstring prog_time_;
  std::wstring prog_title_;
  std::wstring line_label_;
  std::wstring zap_digits_;
  std::wstring live_error_;
  bool catchup_bar_ = false;
  bool catchup_seek_ = true;
  std::wstring pill_label_;
  std::wstring catchup_scale_;
  std::wstring catchup_player_;
  std::wstring catchup_decode_;
  std::wstring catchup_direct_;
  std::wstring catchup_across_;
  std::wstring catchup_invert_;
  std::wstring catchup_fail_;
  bool fullscreen_active_ = false;

  // 缓冲浮层（KotvBufferingOverlay）：文案非空即显示，转圈按 tick 动画。
  std::wstring buffer_text_;
  DWORD spin_tick0_ = 0;

  // KotvMarqueeText：本次绘制中有溢出跑马的面板（位掩码），定时器按 marquee_tick0_ 推进。
  PanelId painting_ = kPanelCount;
  uint32_t marquee_panels_ = 0;
  DWORD marquee_tick0_ = 0;
  bool marquee_running_ = false;

  // 全屏上下滑切集：画面跟手位移（逻辑像素）与上一集 / 下一集提示页
  double swipe_dy_ = 0;
  std::wstring swipe_prev_;
  std::wstring swipe_next_;

  std::string channel_logo_;

  // 迷你
  bool mini_hover_ = false;
  bool mini_bar_shown_ = false;

  // 音量展开
  bool volume_expanded_ = false;
  bool volume_hover_ = false;

  // 弹层
  std::string sheet_kind_;
  std::wstring sheet_title_;
  std::wstring sheet_subtitle_;
  std::vector<LineItem> sheet_items_;
  int sheet_scroll_ = 0;
  int sheet_content_h_ = 0;
  RECT sheet_card_{};
  RECT popup_anchor_{};
  bool popup_open_ = false;

  // 指针
  PanelId drag_panel_ = kPanelCount;
  std::string drag_id_;
  int drag_index_ = -1;
  RECT drag_rc_{};
  double drag_value_ = 0;
  bool pointer_hold_ = false;
  bool hold_btn_down_ = false;
  bool panel_hover_[kPanelCount] = {};

  // 手势层
  bool ges_down_ = false;
  bool ges_hold_fired_ = false;
  POINT ges_down_pt_{};
  bool ges_tracking_ = false;
  // 面板显隐时系统会补发同坐标的 WM_MOUSEMOVE，不能当作悬停（否则右键收起的播控又被唤出）。
  DWORD last_move_pos_ = 0xFFFFFFFF;

  // HUD
  HudKind hud_kind_ = HudKind::None;
  std::wstring hud_text_;
  uint32_t hud_icon_ = 0;
  double hud_size_ = 18;
  bool hud_ui_ = true;

  // 弹幕
  bool danmaku_enabled_ = false;
  double danmaku_font_ = 18;
  double danmaku_opacity_ = 0.85;
  int danmaku_duration_ms_ = 8000;
  int danmaku_fixed_ms_ = 5000;
  int danmaku_rows_ = 6;
  int danmaku_max_on_screen_ = 60;
  double danmaku_scroll_area_ = 1.0;
  bool danmaku_bold_ = false;
  bool danmaku_show_scroll_ = true;
  bool danmaku_show_top_ = true;
  bool danmaku_show_bottom_ = true;
  bool danmaku_show_reverse_ = true;
  bool danmaku_show_positioned_ = true;
  bool danmaku_show_special_ = true;
  std::vector<DanmakuItem> danmaku_items_;
  std::vector<DanmakuFlying> danmaku_flying_;
  size_t danmaku_cursor_ = 0;
  double danmaku_last_sec_ = -1;
  double danmaku_line_spacing_ = 1.4;
  std::string danmaku_stroke_mode_ = "outline";
  std::string danmaku_color_mode_ = "original";
  int danmaku_rows_top_ = 3;
  int danmaku_rows_bottom_ = 3;
  double danmaku_scroll_gap_ = 0.08;
  double danmaku_stroke_width_ = 0.12;
  double danmaku_shadow_opacity_ = 0.5;
  double danmaku_proj_x_ = 0.08;
  double danmaku_proj_y_ = 0.08;
  double danmaku_proj_opacity_ = 0.2;
  bool danmaku_timer_ = false;
  bool danmaku_painted_empty_ = false;
};

#endif  // RUNNER_WIN7_CHROME_SHELL_H_
