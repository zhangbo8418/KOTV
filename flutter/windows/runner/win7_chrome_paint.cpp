// Win7 原生播控绘制：数值逐项对齐 Flutter 播控组件（见各函数注释里的组件名）。
#include "win7_chrome_shell.h"

#include <algorithm>
#include <cmath>
#include <ctime>

using kotv_chrome::Argb;
using kotv_chrome::Canvas;
using kotv_chrome::WithOpacity;
namespace ic = kotv_chrome::icon;

namespace {

constexpr Argb kWhite = 0xFFFFFFFF;
constexpr Argb kAccent = 0xFFE52D27;
constexpr Argb kKotvPrimary = 0xFFCF4274;  // KotvColors.primary
constexpr Argb kWhite24 = 0x3DFFFFFF;
constexpr Argb kWhite38 = 0x61FFFFFF;
constexpr UINT kLeft = DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS;
constexpr UINT kCenterFmt = DT_CENTER | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS;
constexpr UINT kRight = DT_RIGHT | DT_VCENTER | DT_SINGLELINE;

std::wstring FmtPlayerTime(double sec) {
  const long long s = static_cast<long long>(std::max(0.0, sec));
  wchar_t buf[32];
  if (s >= 3600) {
    swprintf_s(buf, L"%lld:%02lld:%02lld", s / 3600, (s % 3600) / 60, s % 60);
  } else {
    swprintf_s(buf, L"%02lld:%02lld", s / 60, s % 60);
  }
  return buf;
}

std::wstring FmtClockHms(double sec) {
  const long long s = static_cast<long long>(std::max(0.0, sec));
  wchar_t buf[32];
  swprintf_s(buf, L"%02lld:%02lld:%02lld", s / 3600, (s % 3600) / 60, s % 60);
  return buf;
}

std::wstring FmtMmSs(int sec) {
  const int s = std::max(0, sec);
  wchar_t buf[16];
  swprintf_s(buf, L"%02d:%02d", s / 60, s % 60);
  return buf;
}

RECT R(int l, int t, int r, int b) { return RECT{l, t, r, b}; }

struct LiveCols {
  int group = 0, channel = 0, epg = 0, tab = 0;
  int pad_h = 0, pad_v = 0, gap1 = 0, gap_tab = 0, gap2 = 0;
  int panel_w = 0;
};

}  // namespace

// ---------------------------------------------------------------------------
// 尺寸
// ---------------------------------------------------------------------------

int Win7ChromeShell::InlineBarH(int w) const {
  const bool narrow = IsMini() || w / dpr_ < 480;
  return G(narrow ? 2 : 6) * 2 + G(narrow ? 32 : 40) + G(24);
}

int Win7ChromeShell::FullscreenTopH() const {
  static Canvas m;
  const int text = m.LineHeight(F(land_ ? 16 : 22), 700) + m.LineHeight(F(land_ ? 11 : 14), 400);
  return P(land_ ? 6 : 12) + std::max(P(land_ ? 28 : 42), text) + P(land_ ? 8 : 14);
}

int Win7ChromeShell::FullscreenBottomH() const {
  static Canvas m;
  const int clock = static_cast<int>(std::lround(F(land_ ? 20 : 32)));
  const int ends = m.LineHeight(F(land_ ? 11 : 13), 400);
  const int seek = std::max(G(24), m.LineHeight(F(land_ ? 11 : 13), 400));
  const int act = G(10) * 2 + m.LineHeight(F(14), 700);
  const int row = std::max(G(land_ ? 32 : 40), act);
  return P(land_ ? 6 : 12) + clock + ends + P(land_ ? 2 : 4) + seek + P(land_ ? 2 : 6) + row + P(land_ ? 10 : 22);
}

int Win7ChromeShell::CatchupBarH(int w) const {
  (void)w;
  const int row = G(land_ ? 30 : 40);
  const int seek = catchup_seek_ ? G(land_ ? 10 : 12) * 2 : 0;
  return G(land_ ? 2 : 4) + row + seek + G(land_ ? 4 : 6);
}

int Win7ChromeShell::ChannelBarH() const {
  static Canvas m;
  const int text = m.LineHeight(F(18), 600) + m.LineHeight(F(13), 400);
  return P(12) * 2 + std::max(P(36), text);
}

int Win7ChromeShell::LiveRightW(int host_w) const {
  const double w = host_w / dpr_;
  if (land_) return static_cast<int>(std::lround(std::clamp(w * 0.30, 180.0, 240.0) * grow_ * dpr_));
  return G(240);
}

static LiveCols ComputeLiveCols(double ui, double dpr, bool land, bool epg_open, bool immersive, int host_w,
                                int channel_floor) {
  auto px = [&](double v) { return static_cast<int>(std::lround(v * ui * dpr)); };
  LiveCols c;
  c.group = px(land ? 112 : 136);
  c.channel = px(land ? 248 : 280);
  c.epg = px(land ? 200 : 260);
  c.tab = px(land ? 28 : 32);
  c.pad_h = px(land ? 6 : 8);
  c.pad_v = px(land ? 8 : 10);
  c.gap1 = px(land ? 4 : 6);
  c.gap_tab = px(land ? 4 : 6);
  c.gap2 = px(6);
  const double max_frac = (immersive && !land) ? 0.52 : 0.92;
  const int content = c.group + c.gap1 + c.channel + c.gap_tab + c.tab + (epg_open ? c.gap2 + c.epg : 0);
  c.panel_w = std::min(content + c.pad_h * 2, static_cast<int>(host_w * max_frac));
  const int inner = std::max(1, c.panel_w - c.pad_h * 2);
  if (content > inner) {
    int over = content - inner;
    auto shrink = [&](int& v, int floor) {
      const int take = std::min(over, std::max(0, v - floor));
      v -= take;
      over -= take;
    };
    shrink(c.channel, channel_floor);
    if (epg_open) shrink(c.epg, px(land ? 120 : 140));
    shrink(c.group, px(land ? 72 : 88));
    shrink(c.tab, px(land ? 24 : 28));
  }
  return c;
}

int Win7ChromeShell::LiveLeftW(int host_w) const {
  static Canvas m;
  const float font = F(land_ ? 12 : 13);
  const int num_w = static_cast<int>(std::clamp((font / dpr_ / text_scale_) * 0.62 * channel_digits_ + 10, 40.0, 120.0) * grow_ * dpr_);
  const int floor = num_w + G(land_ ? 4 : 12) + G(land_ ? 28 : 40) + G(land_ ? 6 : 12) + G(56);
  return ComputeLiveCols(grow_, dpr_, land_, epg_open_, fullscreen_active_, host_w, floor).panel_w;
}

// ---------------------------------------------------------------------------
// 通用小部件
// ---------------------------------------------------------------------------

void Win7ChromeShell::Paint(PanelId id, Canvas& cv, std::vector<Hit>& hits) {
  switch (id) {
    case kTop: PaintTop(cv, hits); break;
    case kBottom:
      if (mode_ == "vod_inline") PaintInlineBar(cv, hits, false);
      else if (mode_ == "vod") PaintFullscreenBottom(cv, hits);
      else if (mode_ == "live") PaintCatchupBar(cv, hits, false);
      else if (IsMini()) {
        if (mini_kind_ == "live") PaintCatchupBar(cv, hits, true);
        else PaintInlineBar(cv, hits, true);
      }
      break;
    case kEpisodes: PaintEpisodes(cv, hits); break;
    case kLiveLeft: PaintLiveLeft(cv, hits); break;
    case kLiveRight: PaintLiveRight(cv, hits); break;
    case kChannel: PaintChannel(cv); break;
    case kCenter: PaintCenter(cv, hits); break;
    case kPill: PaintPill(cv, hits); break;
    case kDebug: PaintDebug(cv); break;
    case kHud: PaintHud(cv); break;
    case kZap: PaintZap(cv); break;
    case kSheet: PaintSheet(cv, hits); break;
    case kPopup: PaintPopup(cv, hits); break;
    default: break;
  }
}

// _IconAct：方框 size*ui，图标 (size<=34?18:22)*ui，角标贴右上。
int Win7ChromeShell::PaintIconAct(Canvas& cv, std::vector<Hit>& hits, const char* id, int x, int y, int box,
                                  uint32_t cp, const std::wstring& badge) {
  const RECT rc = R(x, y, x + box, y + box);
  const bool small = box <= G(34);
  cv.Icon(rc, cp, static_cast<float>(G(small ? 18 : 22)), kWhite);
  if (!badge.empty()) {
    const float fs = F(9);
    const int tw = cv.Measure(badge, fs, 700);
    const int th = cv.LineHeight(fs, 700);
    const int bw = tw + G(3) * 2;
    const int bh = th + G(1) * 2;
    const RECT b = R(rc.right - G(2) - bw, rc.top + G(2), rc.right - G(2), rc.top + G(2) + bh);
    cv.RoundRect(b, static_cast<float>(G(4)), kAccent);
    cv.Text(b, badge, kWhite, fs, 700, kCenterFmt);
  }
  hits.push_back(Hit{id, rc, -1});
  return box;
}

// _TextAct：内边距 10*ui，14 w600 白。
int Win7ChromeShell::PaintTextAct(Canvas& cv, std::vector<Hit>& hits, const char* id, int x, int cy,
                                  const std::wstring& label, float px, int pad) {
  const int tw = cv.Measure(label, px, 700);
  const int th = cv.LineHeight(px, 700);
  const RECT rc = R(x, cy - th / 2 - pad, x + tw + pad * 2, cy - th / 2 + th + pad);
  cv.Text(R(rc.left + pad, rc.top + pad, rc.right - pad, rc.bottom - pad), label, kWhite, px, 700, kLeft);
  hits.push_back(Hit{id, rc, -1});
  return rc.right - rc.left;
}

// Slider（RoundedRectSliderTrackShape：激活段比轨道高 2；两端各让出 overlay 半径）。
void Win7ChromeShell::PaintSlider(Canvas& cv, const RECT& area, double frac, double secondary, int track_h,
                                  int thumb_r, int inset, Argb active, Argb inactive, Argb secondary_c, Argb thumb) {
  frac = std::clamp(frac, 0.0, 1.0);
  secondary = std::clamp(secondary, 0.0, 1.0);
  const int l = area.left + inset;
  const int r = area.right - inset;
  if (r <= l) return;
  const int cy = (area.top + area.bottom) / 2;
  const int x = l + static_cast<int>(std::lround((r - l) * frac));
  const float rad = track_h / 2.0f;
  cv.RoundRect(R(l, cy - track_h / 2, r, cy - track_h / 2 + track_h), rad, inactive);
  if ((secondary_c >> 24) && secondary > frac) {
    const int sx = l + static_cast<int>(std::lround((r - l) * secondary));
    cv.RoundRect(R(l, cy - track_h / 2, sx, cy - track_h / 2 + track_h), rad, secondary_c);
  }
  const int ah = track_h + 2;
  if (x > l) cv.RoundRect(R(l, cy - ah / 2, x, cy - ah / 2 + ah), ah / 2.0f, active);
  cv.Circle(static_cast<float>(x), static_cast<float>(cy), static_cast<float>(thumb_r), thumb);
}

// KotvVolumeControl：右侧喇叭；悬停展开滑条（宽 sliderWidth*ui）。
int Win7ChromeShell::PaintVolume(Canvas& cv, std::vector<Hit>& hits, int right, int cy, int box, bool compact,
                                 double slider_w) {
  const bool small = box <= G(34);
  const int glyph = G(compact ? (small ? 18 : 20) : (small ? 18 : 22));
  const double vol = std::clamp(volume_, 1.0, 100.0);
  const uint32_t cp = vol <= 1 ? ic::kVolumeMute : (vol < 35 ? ic::kVolumeDown : ic::kVolumeUp);
  const RECT icon_rc = R(right - box, cy - box / 2, right, cy - box / 2 + box);
  cv.Icon(icon_rc, cp, static_cast<float>(glyph), kWhite);
  hits.push_back(Hit{"volIcon", icon_rc, -1});
  int left = icon_rc.left;
  if (volume_expanded_) {
    const int sw = static_cast<int>(std::lround(slider_w));
    const int overlay = P(compact ? 10 : 12);
    const RECT area = R(left - sw, cy - overlay, left, cy + overlay);
    PaintSlider(cv, area, (vol - 1) / 99.0, 0, P(compact ? 2 : 3), P(compact ? 5 : 6), overlay, kKotvPrimary,
                kWhite24, 0, kWhite);
    hits.push_back(Hit{"volume", area, -1});
    left = area.left;
  }
  return left;
}

// AppPill：底 pillBg / 选中 selected；描边 pillBorder / primary@0.9；圆角 8*s；字 w700。
void Win7ChromeShell::PaintAppPill(Canvas& cv, const RECT& rc, const std::wstring& label, const std::wstring& suffix,
                                   double font, bool selected) {
  const float r = static_cast<float>(L(8));
  cv.RoundRect(rc, r, selected ? pal_selected_ : pal_pill_bg_, selected ? WithOpacity(pal_primary_, 0.9) : pal_pill_border_,
               1.0f);
  const Argb fg = selected ? kWhite : pal_fg_;
  const float fs = FL(font);
  const int pad = L(14);
  RECT inner = R(rc.left + pad, rc.top, rc.right - pad, rc.bottom);
  if (suffix.empty()) {
    cv.Text(inner, label, fg, fs, 700, kCenterFmt);
    return;
  }
  const int sw = cv.Measure(suffix, fs, 700);
  const int lw = cv.Measure(label, fs, 700);
  const int avail = inner.right - inner.left;
  const int total = std::min(avail, lw + sw);
  const int x0 = inner.left + (avail - total) / 2;
  cv.Text(R(x0, rc.top, x0 + total - sw, rc.bottom), label, fg, fs, 700, kLeft);
  cv.Text(R(x0 + total - sw, rc.top, x0 + total, rc.bottom), suffix, fg, fs, 700, kLeft);
}

// ---------------------------------------------------------------------------
// 点播
// ---------------------------------------------------------------------------

// VodInlineControls（mini 时叠 MiniHoverShell 渐变，底色 0x660A0A12）。
void Win7ChromeShell::PaintInlineBar(Canvas& cv, std::vector<Hit>& hits, bool mini) {
  const int W = cv.width();
  const int H = cv.height();
  const bool narrow = mini || W / dpr_ < 480;
  if (mini) {
    cv.VGradient(R(0, 0, W, H), 0x00000000, 0x8C000000);
    cv.Fill(R(0, 0, W, H), 0x660A0A12);
  } else {
    cv.Fill(R(0, 0, W, H), 0xCC0A0A12);
  }
  const int pad_h = G(narrow ? 4 : 8);
  const int pad_v = G(narrow ? 2 : 6);
  const int box = G(narrow ? 32 : 40);
  int x = pad_h;
  const int y = pad_v;
  x += PaintIconAct(cv, hits, "toggle", x, y, box, playing_ ? ic::kPause : ic::kPlay, L"");
  x += PaintIconAct(cv, hits, "stop", x, y, box, ic::kStop, L"");
  if (show_direct_) x += PaintIconAct(cv, hits, "direct", x, y, box, direct_on_ ? ic::kFlashOn : ic::kFlashOff, L"");
  if (has_cast_) x += PaintIconAct(cv, hits, "cast", x, y, box, ic::kCast, L"");
  if (has_mini_ || mini) x += PaintIconAct(cv, hits, "mini", x, y, box, mini ? ic::kCloseFullscreen : ic::kPip, L"");
  if (!mini) x += PaintIconAct(cv, hits, "expand", x, y, box, ic::kFullscreen, L"");
  x += G(narrow ? 4 : 8);
  const int vol_left = PaintVolume(cv, hits, W - pad_h, y + box / 2, box, narrow, G(narrow ? 72 : 110));
  const std::wstring dur = bounded_ ? FmtPlayerTime(duration_sec_) : L"--:--";
  cv.Text(R(x, y, vol_left, y + box), FmtPlayerTime(position_sec_) + L" / " + dur, WithOpacity(kWhite, 0.75),
          F(narrow ? 11 : 12), 400, kLeft);
  const RECT seek = R(pad_h, y + box, W - pad_h, y + box + G(24));
  const double total = bounded_ && duration_sec_ > 0 ? duration_sec_ : std::max(position_sec_, 0.001);
  PaintSlider(cv, seek, position_sec_ / total, std::max(buffered_sec_, position_sec_) / total, G(3), G(6), G(12),
              kKotvPrimary, kWhite24, kWhite38, kWhite);
  hits.push_back(Hit{"seek", seek, -1});
}

// VodFullscreenChrome 顶栏。
void Win7ChromeShell::PaintTop(Canvas& cv, std::vector<Hit>& hits) {
  const int W = cv.width();
  const int H = cv.height();
  cv.Fill(R(0, 0, W, H), 0x66000000);
  const int pad_h = P(land_ ? 14 : 28);
  const int top = P(land_ ? 6 : 12);
  const int bottom = P(land_ ? 8 : 14);
  const int cy = (top + H - bottom) / 2;
  const int accent_h = P(land_ ? 28 : 42);
  cv.Fill(R(pad_h, cy - accent_h / 2, pad_h + P(4), cy - accent_h / 2 + accent_h), kAccent);
  const int exit_w = cv.Measure(L"退出", F(14), 700) + G(10) * 2;
  const int exit_x = W - pad_h - exit_w;
  PaintTextAct(cv, hits, "exit", exit_x, cy, L"退出", F(14), G(10));
  const int tx = pad_h + P(4) + P(10);
  const float ts = F(land_ ? 16 : 22);
  const float rs = F(land_ ? 11 : 14);
  const int th = cv.LineHeight(ts, 700);
  const int rh = cv.LineHeight(rs, 400);
  const int ty = cy - (th + rh) / 2;
  cv.Text(R(tx, ty, exit_x, ty + th), title_, kWhite, ts, 700, kLeft);
  cv.Text(R(tx, ty + th, exit_x, ty + th + rh), resolution_, WithOpacity(kWhite, 0.7), rs, 400, kLeft);
}

// VodFullscreenChrome 底栏：时钟 / 进度行 / 按钮行 + 音量。
void Win7ChromeShell::PaintFullscreenBottom(Canvas& cv, std::vector<Hit>& hits) {
  const int W = cv.width();
  const int H = cv.height();
  cv.Fill(R(0, 0, W, H), 0x99000000);
  const int pad_h = P(land_ ? 14 : 28);
  int y = P(land_ ? 6 : 12);

  const time_t now_t = time(nullptr);
  tm now{};
  localtime_s(&now, &now_t);
  wchar_t clock[16];
  swprintf_s(clock, L"%02d:%02d:%02d", now.tm_hour, now.tm_min, now.tm_sec);
  const float cs = F(land_ ? 20 : 32);
  const int ch = static_cast<int>(std::lround(cs));
  cv.Text(R(pad_h, y - ch / 6, W - pad_h, y + ch + ch / 6), clock, kWhite, cs, 700, kRight);
  y += ch;
  std::wstring ends = L"Ends at --:--";
  if (bounded_ && duration_sec_ > 0 && duration_sec_ >= position_sec_) {
    const time_t end_t = now_t + static_cast<time_t>(duration_sec_ - position_sec_);
    tm end{};
    localtime_s(&end, &end_t);
    wchar_t buf[32];
    swprintf_s(buf, L"Ends at %02d:%02d", end.tm_hour, end.tm_min);
    ends = buf;
  }
  const float es = F(land_ ? 11 : 13);
  const int eh = cv.LineHeight(es, 400);
  cv.Text(R(pad_h, y, W - pad_h, y + eh), ends, WithOpacity(kWhite, 0.7), es, 400, kRight);
  y += eh + P(land_ ? 2 : 4);

  const float ts = F(land_ ? 11 : 13);
  const int seek_h = std::max(G(24), cv.LineHeight(ts, 400));
  const int col = P(land_ ? 64 : 78);
  cv.Text(R(pad_h, y, pad_h + col, y + seek_h), bounded_ ? FmtClockHms(position_sec_) : L"--:--:--",
          WithOpacity(kWhite, 0.75), ts, 400, kLeft);
  cv.Text(R(W - pad_h - col, y, W - pad_h, y + seek_h), bounded_ ? FmtClockHms(duration_sec_) : L"--:--:--",
          WithOpacity(kWhite, 0.75), ts, 400, kRight);
  const RECT seek = R(pad_h + col, y + (seek_h - G(24)) / 2, W - pad_h - col, y + (seek_h - G(24)) / 2 + G(24));
  const double total = bounded_ && duration_sec_ > 0 ? duration_sec_ : std::max(position_sec_, 0.001);
  PaintSlider(cv, seek, position_sec_ / total, std::max(buffered_sec_, position_sec_) / total, G(3), G(6), G(12),
              kKotvPrimary, kWhite24, kWhite38, kWhite);
  hits.push_back(Hit{"seek", seek, -1});
  y += seek_h + P(land_ ? 2 : 6);

  const int box = G(land_ ? 32 : 40);
  const int row_h = std::max(box, G(10) * 2 + cv.LineHeight(F(14), 700));
  const int cy = y + row_h / 2;
  const int vol_left = PaintVolume(cv, hits, W - pad_h, cy, box, land_, G(140));
  const int limit = vol_left - P(10);
  cv.SetClip(R(pad_h, y, limit, y + row_h));
  int x = pad_h;
  const int iy = cy - box / 2;
  x += PaintIconAct(cv, hits, "prev", x, iy, box, ic::kSkipPrev, L"");
  x += PaintIconAct(cv, hits, "toggle", x, iy, box, playing_ ? ic::kPause : ic::kPlay, L"");
  x += PaintIconAct(cv, hits, "next", x, iy, box, ic::kSkipNext, L"");
  x += PaintIconAct(cv, hits, "speed", x, iy, box, ic::kFastForward, speed_badge_);
  x += PaintIconAct(cv, hits, "replay", x, iy, box, ic::kReplay, L"");
  x += PaintIconAct(cv, hits, "aspect", x, iy, box, ic::kAspect, aspect_badge_);
  x += PaintIconAct(cv, hits, "decode", x, iy, box, ic::kMemory, decode_badge_);
  if (show_direct_) x += PaintIconAct(cv, hits, "direct", x, iy, box, direct_on_ ? ic::kFlashOn : ic::kFlashOff, L"");
  x += PaintIconAct(cv, hits, "subtitle", x, iy, box, ic::kClosedCaption, L"");
  if (show_disc_) x += PaintIconAct(cv, hits, "disc", x, iy, box, ic::kAlbumOutlined, L"");
  x += PaintIconAct(cv, hits, "audio", x, iy, box, ic::kAudiotrack, L"");
  x += PaintIconAct(cv, hits, "video", x, iy, box, ic::kVideocamOutlined, L"");
  if (show_player_) x += PaintIconAct(cv, hits, "player", x, iy, box, ic::kDevices, player_badge_);
  x += P(6);
  cv.Fill(R(x, cy - P(13), x + P(1), cy + P(13)), 0x4DFFFFFF);
  x += P(1) + P(8);

  // _TinyBtn：0x33FFFFFF 底，圆角 6*ui，内边距 8/4*ui，12 号；_OffsetClock：6/4*ui，13 w600。
  auto tiny = [&](const char* id, const std::wstring& label) {
    const float fs = F(12);
    const int w = cv.Measure(label, fs, 400) + G(8) * 2;
    const int h = cv.LineHeight(fs, 400) + G(4) * 2;
    const RECT rc = R(x, cy - h / 2, x + w, cy - h / 2 + h);
    cv.RoundRect(rc, static_cast<float>(G(6)), 0x33FFFFFF);
    cv.Text(rc, label, kWhite, fs, 400, kCenterFmt);
    hits.push_back(Hit{id, rc, -1});
    x += w;
  };
  auto clock_text = [&](const std::wstring& label) {
    const float fs = F(13);
    const int w = cv.Measure(label, fs, 700) + G(6) * 2;
    cv.Text(R(x, cy - row_h / 2, x + w, cy + row_h / 2), label, kWhite, fs, 700, kCenterFmt);
    x += w;
  };
  tiny("offset:openSet", L"片头");
  x += P(8);
  tiny("offset:openDec", L"-");
  clock_text(FmtMmSs(opening_sec_));
  tiny("offset:openInc", L"+");
  x += P(8);
  tiny("offset:endSet", L"片尾");
  x += P(8);
  tiny("offset:endDec", L"-");
  clock_text(FmtMmSs(ending_sec_));
  tiny("offset:endInc", L"+");
  x += P(8);
  tiny("offset:reset", L"重置");
  x += P(8);
  cv.Fill(R(x, cy - P(13), x + P(1), cy + P(13)), 0x4DFFFFFF);
  x += P(1) + P(4);
  x += PaintTextAct(cv, hits, "more", x, cy, L"更多", F(14), G(10));
  if (!episodes_.empty()) x += PaintTextAct(cv, hits, "episodes", x, cy, L"选集", F(14), G(10));
  cv.ClearClip();
  for (auto& h : hits) {
    if (h.id == "volIcon" || h.id == "volume" || h.id == "seek") continue;
    if (h.rc.right > limit) h.rc.right = std::max(h.rc.left, static_cast<LONG>(limit));
  }
}

// VodFullscreenChrome 右侧选集面板（桌面宽 280）。
void Win7ChromeShell::PaintEpisodes(Canvas& cv, std::vector<Hit>& hits) {
  const int W = cv.width();
  const int H = cv.height();
  cv.Fill(R(0, 0, W, H), 0xF0120A1C);
  const float hs = F(land_ ? 16 : 20);
  const int top = P(land_ ? 8 : 14);
  const int row = std::max(P(48), cv.LineHeight(hs, 700));
  cv.Text(R(P(16), top, W - P(8) - P(48), top + row), L"选集", kWhite, hs, 700, kLeft);
  const RECT close = R(W - P(8) - P(48), top, W - P(8), top + row);
  cv.Icon(close, ic::kClose, static_cast<float>(P(24)), 0xB3FFFFFF);
  hits.push_back(Hit{"closeEpisodes", close, -1});
  const int div_y = top + row + P(10);
  cv.Fill(R(0, div_y, W, div_y + 1), 0x44FFFFFF);
  const RECT list = R(0, div_y + 1, W, H);
  const int view_h = list.bottom - list.top;
  const int extent = P(48);
  const int pad_v = P(8);
  const int content = pad_v * 2 + extent * static_cast<int>(episodes_.size());
  if (episode_pinned_ != episode_selected_) {
    episode_pinned_ = episode_selected_;
    if (episode_selected_ >= 0) {
      const int off = episode_selected_ <= 0 ? 0 : pad_v + episode_selected_ * extent;
      if (off < episode_scroll_ || off + extent > episode_scroll_ + view_h) episode_scroll_ = off;
    }
  }
  episode_scroll_ = std::clamp(episode_scroll_, 0, std::max(0, content - view_h));
  cv.SetClip(list);
  for (int i = 0; i < static_cast<int>(episodes_.size()); ++i) {
    const int iy = list.top + pad_v + i * extent - episode_scroll_;
    if (iy + extent < list.top || iy > list.bottom) continue;
    const bool sel = i == episode_selected_;
    const RECT tile = R(P(10), iy + P(3), W - P(10), iy + extent - P(3));
    cv.RoundRect(tile, static_cast<float>(P(8)), sel ? 0x3DFFFFFF : 0xFF1C1826);
    cv.Text(R(tile.left + P(14), tile.top, tile.right - P(14), tile.bottom), episodes_[i],
            WithOpacity(kWhite, sel ? 1.0 : 0.9), F(15), sel ? 700 : 500, kLeft);
    RECT hit = tile;
    IntersectRect(&hit, &hit, &list);
    hits.push_back(Hit{"episode", hit, i});
  }
  cv.ClearClip();
}

// CenterPlayPauseButton：0x73000000 圆，图标 size*0.58。
void Win7ChromeShell::PaintCenter(Canvas& cv, std::vector<Hit>& hits) {
  const int d = std::min(cv.width(), cv.height());
  cv.Circle(d / 2.0f, d / 2.0f, d / 2.0f, 0x73000000);
  cv.Icon(R(0, 0, d, d), playing_ ? ic::kPauseRounded : ic::kPlayRounded, d * 0.58f, kWhite);
  hits.push_back(Hit{"toggle", R(0, 0, d, d), -1});
}

void Win7ChromeShell::PaintDebug(Canvas& cv) {
  cv.RoundRect(R(0, 0, cv.width(), cv.height()), static_cast<float>(P(6)), 0x8A000000);
  const int lh = static_cast<int>(F(11) * 1.35f);
  int y = P(6);
  size_t s = 0;
  while (s <= debug_text_.size()) {
    size_t e = debug_text_.find(L'\n', s);
    if (e == std::wstring::npos) e = debug_text_.size();
    cv.Text(R(P(8), y, cv.width() - P(8), y + lh), debug_text_.substr(s, e - s), 0xB3FFFFFF, F(11), 400, kLeft);
    y += lh;
    s = e + 1;
  }
}

// 手势 HUD（倍速 / 切集提示 / 亮度音量 / seek 预览）。
void Win7ChromeShell::PaintHud(Canvas& cv) {
  const int W = cv.width();
  const int H = cv.height();
  const double u = hud_ui_ ? grow_ : 1.0;
  auto px = [&](double v) { return static_cast<int>(std::lround(v * u * dpr_)); };
  if (hud_kind_ == HudKind::Text) {
    cv.RoundRect(R(0, 0, W, H), static_cast<float>(px(22)), 0x9E000000);
    cv.Text(R(0, 0, W, H), hud_text_, kWhite, F(hud_size_), 700, kCenterFmt);
    return;
  }
  const bool seek = hud_kind_ == HudKind::Seek;
  cv.RoundRect(R(0, 0, W, H), static_cast<float>(px(16)), seek ? 0xB8000000 : 0x9E000000);
  const int icon = px(seek ? 28 : 22);
  const int pad = px(seek ? 22 : 20);
  cv.Icon(R(pad, H / 2 - icon / 2, pad + icon, H / 2 - icon / 2 + icon), hud_icon_, static_cast<float>(icon), kWhite);
  const int tx = pad + icon + px(seek ? 12 : 10);
  cv.Text(R(tx, 0, W, H), hud_text_, kWhite, static_cast<float>(F(seek ? 18 : 16) * u), 700, kLeft);
}

void Win7ChromeShell::PaintZap(Canvas& cv) {
  const int W = cv.width();
  const int H = cv.height();
  if (!zap_digits_.empty()) {
    const RECT rc = R(P(8), P(8), W - P(8), H - P(8));
    RECT sh = rc;
    OffsetRect(&sh, P(1), P(2));
    cv.Text(sh, zap_digits_, 0x8A000000, F(56), 800, kRight);
    cv.Text(rc, zap_digits_, WithOpacity(kWhite, 0.92), F(56), 800, kRight);
    return;
  }
  cv.Text(R(0, 0, W, H), live_error_, 0xB3FFFFFF, F(14), 400, kCenterFmt);
}

// ---------------------------------------------------------------------------
// 直播
// ---------------------------------------------------------------------------

// LiveCatchupChrome（mini 时叠 MiniHoverShell 渐变）。
void Win7ChromeShell::PaintCatchupBar(Canvas& cv, std::vector<Hit>& hits, bool mini) {
  const int W = cv.width();
  const int H = cv.height();
  if (mini) {
    cv.VGradient(R(0, 0, W, H), 0x00000000, 0x8C000000);
    cv.Fill(R(0, 0, W, H), 0x660A0A12);
  } else {
    cv.Fill(R(0, 0, W, H), 0xCC0A0A12);
  }
  const bool compact = mini || W / dpr_ < 560 || land_;
  const int pad_h = G(compact ? 4 : 10);
  const int top = G(land_ ? 2 : 4);
  const int box = G(land_ ? 30 : 40);
  const int glyph = G((land_ ? 30 : 40) <= 32 ? 16 : 22);
  const int cy = top + box / 2;
  int x = pad_h;
  auto act = [&](const char* id, uint32_t cp) {
    const RECT rc = R(x, top, x + box, top + box);
    cv.Icon(rc, cp, static_cast<float>(glyph), kWhite);
    hits.push_back(Hit{id, rc, -1});
    x += box;
  };
  act("toggle", playing_ ? ic::kPause : ic::kPlay);
  if (has_cast_) act("cast", ic::kCast);
  act("mini", mini ? ic::kCloseFullscreen : ic::kPip);
  if (!mini) act("expand", fullscreen_active_ ? ic::kFullscreenExit : ic::kFullscreen);
  const int vol_left = PaintVolume(cv, hits, W - pad_h, cy, box, compact, G(compact ? 72 : (land_ ? 90 : 110)));
  cv.SetClip(R(x, 0, vol_left, top + box));
  auto text_act = [&](const char* id, const std::wstring& label) {
    if (label.empty()) return;
    x += PaintTextAct(cv, hits, id, x, cy, label, F(13), G(8));
  };
  if (!compact) {
    text_act("right:player", catchup_player_);
    text_act("right:decode", catchup_decode_);
    text_act("right:direct", catchup_direct_);
  }
  text_act("right:scale", catchup_scale_);
  text_act("right:across", catchup_across_);
  text_act("right:invert", catchup_invert_);
  text_act("right:failSwitch", catchup_fail_);
  if (catchup_seek_) {
    x += P(6);
    const std::wstring dur = bounded_ ? FmtPlayerTime(duration_sec_) : L"--:--";
    const std::wstring t = compact ? FmtPlayerTime(position_sec_) : FmtPlayerTime(position_sec_) + L" / " + dur;
    cv.Text(R(x, top, vol_left, top + box), t, WithOpacity(kWhite, 0.75), F(land_ ? 11 : (compact ? 11 : 12)), 400,
            DT_LEFT | DT_VCENTER | DT_SINGLELINE);
  }
  cv.ClearClip();
  for (auto& h : hits) {
    if (h.id.rfind("right:", 0) == 0 && h.rc.right > vol_left) h.rc.right = std::max(h.rc.left, static_cast<LONG>(vol_left));
  }
  if (catchup_seek_) {
    const int overlay = G(land_ ? 10 : 12);
    const RECT seek = R(pad_h, top + box, W - pad_h, top + box + overlay * 2);
    const double total = bounded_ && duration_sec_ > 0 ? duration_sec_ : std::max(position_sec_, 0.001);
    PaintSlider(cv, seek, position_sec_ / total, std::max(buffered_sec_, position_sec_) / total, G(land_ ? 2 : 3),
                G(land_ ? 5 : 6), overlay, kKotvPrimary, kWhite24, kWhite38, kWhite);
    if (bounded_) hits.push_back(Hit{"catchupSeek", seek, -1});
  }
}

// 直播左栏：分组 AppPill / 频道行 / 节目单竖签 / EPG 列。
void Win7ChromeShell::PaintLiveLeft(Canvas& cv, std::vector<Hit>& hits) {
  const int W = cv.width();
  const int H = cv.height();
  cv.Fill(R(0, 0, W, H), pal_dialog_bg_);
  const float font = F(land_ ? 12 : 13);
  const int num_w = static_cast<int>(std::clamp((land_ ? 12.0 : 13.0) * 0.62 * channel_digits_ + 10, 40.0, 120.0) * grow_ * dpr_);
  const int logo_w = G(land_ ? 28 : 40);
  const int logo_h = G(land_ ? 22 : 30);
  const int floor = num_w + G(land_ ? 4 : 12) + logo_w + G(land_ ? 6 : 12) + G(56);
  RECT host = HostClient();
  const RECT box = VideoArea();
  (void)host;
  const LiveCols c = ComputeLiveCols(grow_, dpr_, land_, epg_open_, fullscreen_active_, box.right - box.left, floor);
  const int top = c.pad_v;
  const int bottom = H - c.pad_v;
  const int view_h = bottom - top;
  int x = c.pad_h;

  auto pin = [&](int& scroll, int& pinned, int sel, int stride, int count) {
    const int content = stride * count;
    if (pinned != sel) {
      pinned = sel;
      if (sel >= 0) {
        const int off = sel * stride;
        if (off < scroll) scroll = off;
        else if (off + stride > scroll + view_h) scroll = off + stride - view_h;
      }
    }
    scroll = std::clamp(scroll, 0, std::max(0, content - view_h));
  };

  // 分组
  {
    const int pill_h = L(land_ ? 30 : 36);
    const int stride = pill_h + G(land_ ? 4 : 6);
    pin(group_scroll_, group_pinned_, group_selected_, stride, static_cast<int>(groups_.size()));
    const RECT col = R(x, top, x + c.group, bottom);
    hits.push_back(Hit{"col:group", col, -1});
    cv.SetClip(col);
    for (int i = 0; i < static_cast<int>(groups_.size()); ++i) {
      const int iy = top + i * stride - group_scroll_;
      if (iy + pill_h < top || iy > bottom) continue;
      const RECT rc = R(x, iy, x + c.group, iy + pill_h);
      PaintAppPill(cv, rc, groups_[i].label, L"", land_ ? 12 : 13, i == group_selected_);
      RECT hit = rc;
      IntersectRect(&hit, &hit, &col);
      hits.push_back(Hit{"group", hit, i});
    }
    cv.ClearClip();
    x += c.group + c.gap1;
  }

  // 频道
  {
    const int ch_h = G(land_ ? 36 : 48);
    const int stride = ch_h + G(land_ ? 2 : 4);
    pin(channel_scroll_, channel_pinned_, channel_selected_, stride, static_cast<int>(channels_.size()));
    const RECT col = R(x, top, x + c.channel, bottom);
    hits.push_back(Hit{"col:channel", col, -1});
    cv.SetClip(col);
    static const Argb kLogo[] = {0xFFE53935, 0xFFD81B60, 0xFF8E24AA, 0xFF5E35B1, 0xFF3949AB, 0xFF1E88E5,
                                 0xFF039BE5, 0xFF00ACC1, 0xFF00897B, 0xFF43A047, 0xFF7CB342, 0xFFC0CA33,
                                 0xFFFB8C00, 0xFFF4511E, 0xFF6D4C41, 0xFF546E7A};
    for (int i = 0; i < static_cast<int>(channels_.size()); ++i) {
      const int iy = top + i * stride - channel_scroll_;
      if (iy + ch_h < top || iy > bottom) continue;
      const auto& ch = channels_[i];
      const bool sel = i == channel_selected_;
      const RECT rc = R(x, iy, x + c.channel, iy + ch_h);
      cv.RoundRect(rc, static_cast<float>(G(8)), sel ? WithOpacity(pal_selected_, 0.28) : WithOpacity(pal_pill_bg_, 0.55));
      int cx = rc.left + G(6);
      cv.Text(R(cx, rc.top, cx + num_w, rc.bottom), ch.trailing, pal_muted_, F(land_ ? 12 : 16), 400,
              DT_LEFT | DT_VCENTER | DT_SINGLELINE);
      cx += num_w + G(land_ ? 4 : 12);
      std::wstring letter = ch.sub;
      if (letter.empty()) {
        std::wstring s = ch.label;
        while (!s.empty() && s.front() == L' ') s.erase(s.begin());
        if (!s.empty() && s.front() == L'\x2605') s.erase(s.begin());
        while (!s.empty() && s.front() == L' ') s.erase(s.begin());
        letter = s.empty() ? L"！" : s.substr(0, (s.size() > 1 && IS_HIGH_SURROGATE(s[0])) ? 2 : 1);
      }
      unsigned int hcode = 0;
      for (wchar_t wc : letter) hcode = 31 * hcode + static_cast<unsigned int>(wc);
      const RECT logo = R(cx, (rc.top + rc.bottom) / 2 - logo_h / 2, cx + logo_w, (rc.top + rc.bottom) / 2 - logo_h / 2 + logo_h);
      cv.RoundRect(logo, static_cast<float>(P(4)), kLogo[hcode % 16]);
      cv.Text(logo, letter, kWhite, F(12), 600, kCenterFmt);
      cx += logo_w + G(land_ ? 6 : 12);
      cv.Text(R(cx, rc.top, rc.right - G(6), rc.bottom), ch.label, pal_fg_, F(land_ ? 12 : 15), sel ? 700 : 500, kLeft);
      RECT hit = rc;
      IntersectRect(&hit, &hit, &col);
      hits.push_back(Hit{"channel", hit, i});
    }
    cv.ClearClip();
    x += c.channel + c.gap_tab;
  }
  (void)font;

  // 节目单竖签
  {
    const RECT tab = R(x, top, x + c.tab, bottom);
    cv.RoundRect(tab, static_cast<float>(P(8)), epg_open_ ? WithOpacity(pal_selected_, 0.4) : pal_pill_bg_);
    const std::wstring label = epg_open_ ? L"收起" : L"节目单";
    const float fs = F(land_ ? 11 : 12);
    const int lh = static_cast<int>(fs * 1.25f);
    const int total = lh * static_cast<int>(label.size());
    int ty = (top + bottom) / 2 - total / 2;
    for (wchar_t wc : label) {
      cv.Text(R(tab.left, ty, tab.right, ty + lh), std::wstring(1, wc), pal_fg_, fs, 600, kCenterFmt);
      ty += lh;
    }
    hits.push_back(Hit{"epgTab", tab, -1});
    x += c.tab;
  }

  if (!epg_open_) return;
  x += c.gap2;
  {
    const int col_l = x;
    const int col_r = x + c.epg;
    int y = top;
    const float hs = F(land_ ? 11 : 13);
    const int hh = cv.LineHeight(hs, 600);
    cv.Text(R(col_l + G(2), y, col_r, y + hh), L"EPG", pal_muted_, hs, 600, kLeft);
    y += hh + G(land_ ? 4 : 6);
    if (epg_days_.size() > 1) {
      const int tabs_h = P(land_ ? 24 : 28);
      const int pill_w = L(land_ ? 56 : 72);
      const int pill_h = L(land_ ? 22 : 30);
      const int gap = P(land_ ? 3 : 6);
      const int stride = pill_w + gap;
      const int view_w = col_r - col_l;
      const int content = stride * static_cast<int>(epg_days_.size()) - gap;
      if (day_pinned_ != epg_day_selected_) {
        day_pinned_ = epg_day_selected_;
        const int off = epg_day_selected_ * stride;
        if (off < day_scroll_) day_scroll_ = off;
        else if (off + pill_w > day_scroll_ + view_w) day_scroll_ = off + pill_w - view_w;
      }
      day_scroll_ = std::clamp(day_scroll_, 0, std::max(0, content - view_w));
      const RECT strip = R(col_l, y, col_r, y + tabs_h);
      hits.push_back(Hit{"col:days", strip, -1});
      cv.SetClip(strip);
      for (int i = 0; i < static_cast<int>(epg_days_.size()); ++i) {
        const int px = col_l + i * stride - day_scroll_;
        if (px + pill_w < col_l || px > col_r) continue;
        const RECT rc = R(px, y + (tabs_h - pill_h) / 2, px + pill_w, y + (tabs_h - pill_h) / 2 + pill_h);
        PaintAppPill(cv, rc, epg_days_[i], L"", land_ ? 10 : 12, i == epg_day_selected_);
        RECT hit = rc;
        IntersectRect(&hit, &hit, &strip);
        hits.push_back(Hit{"epgDay", hit, i});
      }
      cv.ClearClip();
      y += tabs_h;
    }
    y += G(land_ ? 4 : 6);
    const RECT list = R(col_l, y, col_r, bottom);
    hits.push_back(Hit{"col:epg", list, -1});
    if (programs_.empty()) {
      cv.Text(list, L"暂无节目单", pal_muted_, F(land_ ? 11 : 13), 400, kCenterFmt);
      return;
    }
    const float ls = F(12);
    const int tile_h = static_cast<int>(ls * 1.2f) + G(land_ ? 5 : 8) * 2;
    const int stride = tile_h + G(land_ ? 2 : 4);
    const int list_h = list.bottom - list.top;
    const int content = stride * static_cast<int>(programs_.size());
    if (program_pinned_ != program_selected_) {
      program_pinned_ = program_selected_;
      if (program_selected_ >= 0) {
        const int off = program_selected_ * stride;
        if (off < program_scroll_) program_scroll_ = off;
        else if (off + stride > program_scroll_ + list_h) program_scroll_ = off + stride - list_h;
      }
    }
    program_scroll_ = std::clamp(program_scroll_, 0, std::max(0, content - list_h));
    cv.SetClip(list);
    for (int i = 0; i < static_cast<int>(programs_.size()); ++i) {
      const int iy = list.top + i * stride - program_scroll_;
      if (iy + tile_h < list.top || iy > list.bottom) continue;
      const auto& p = programs_[i];
      const bool sel = p.selected;
      const bool playing = p.on;
      const RECT rc = R(col_l, iy, col_r, iy + tile_h);
      cv.RoundRect(rc, static_cast<float>(G(6)),
                   sel ? WithOpacity(pal_selected_, playing ? 0.95 : 0.75) : WithOpacity(pal_pill_bg_, 0.7));
      int tx = rc.left + G(land_ ? 6 : 8);
      const int ty = rc.top + G(land_ ? 5 : 8);
      const int th = static_cast<int>(ls * 1.2f);
      if (!p.trailing.empty()) {
        const int sw = G(land_ ? 38 : 44);
        cv.Text(R(tx, ty, tx + sw, ty + th), p.trailing, sel ? kWhite : WithOpacity(pal_fg_, 0.75), F(land_ ? 11 : 12),
                400, kLeft);
        tx += sw;
      }
      cv.Text(R(tx, ty, rc.right - G(land_ ? 6 : 8), ty + th), p.label, sel ? kWhite : pal_fg_, ls, sel ? 700 : 500, kLeft);
      RECT hit = rc;
      IntersectRect(&hit, &hit, &list);
      hits.push_back(Hit{"epg", hit, i});
    }
    cv.ClearClip();
  }
}

// 直播右栏「直播设置」：AppPill 列 + 音量 KotvStepSlider + 直播源。
void Win7ChromeShell::PaintLiveRight(Canvas& cv, std::vector<Hit>& hits) {
  const int W = cv.width();
  const int H = cv.height();
  cv.Fill(R(0, 0, W, H), pal_dialog_bg_);
  const int pad = G(land_ ? 8 : 14);
  const RECT view = R(0, 0, W, H);
  struct Row {
    int y, h;
  };
  std::vector<Row> rows(live_right_items_.size());
  int y = pad;
  bool first_pill = true;
  for (size_t i = 0; i < live_right_items_.size(); ++i) {
    const auto& it = live_right_items_[i];
    int h = 0;
    if (it.kind == "title") {
      h = cv.LineHeight(F(land_ ? 14 : 18), 700);
    } else if (it.kind == "label") {
      h = cv.LineHeight(F(14), 400);
    } else if (it.kind == "gap") {
      h = G(it.slider_value);
    } else if (it.kind == "slider") {
      h = P(4) + cv.LineHeight(F(14), 500) + P(28);
    } else {
      const bool src = it.id.rfind("source:", 0) == 0;
      double ph = src ? 36 : 40;
      if (first_pill && !src) {
        ph = land_ ? 30 : 40;
        first_pill = false;
      }
      h = L(ph);
    }
    rows[i] = Row{y, h};
    y += h;
  }
  const int content = y + pad;
  right_scroll_ = std::clamp(right_scroll_, 0, std::max(0, content - H));
  cv.SetClip(view);
  first_pill = true;
  for (size_t i = 0; i < live_right_items_.size(); ++i) {
    const auto& it = live_right_items_[i];
    const int ry = rows[i].y - right_scroll_;
    const int rh = rows[i].h;
    if (ry + rh < 0 || ry > H) {
      if (it.kind == "pill" || it.kind.empty()) first_pill = false;
      continue;
    }
    const RECT rc = R(pad, ry, W - pad, ry + rh);
    if (it.kind == "title") {
      cv.Text(rc, it.label, pal_fg_, F(land_ ? 14 : 18), 700, kLeft);
    } else if (it.kind == "label") {
      cv.Text(rc, it.label, pal_muted_, F(14), 400, kLeft);
    } else if (it.kind == "gap") {
    } else if (it.kind == "slider") {
      const int lh = cv.LineHeight(F(14), 500);
      const RECT lab = R(rc.left, rc.top + P(4), rc.right, rc.top + P(4) + lh);
      cv.Text(lab, it.label, pal_fg_, F(14), 500, kLeft);
      wchar_t buf[16];
      swprintf_s(buf, L"%d", static_cast<int>(std::lround(volume_)));
      cv.Text(lab, buf, pal_muted_, F(13), 400, kRight);
      const RECT area = R(rc.left, lab.bottom, rc.right, lab.bottom + P(28));
      PaintSlider(cv, area, (std::clamp(volume_, 1.0, 100.0) - 1) / 99.0, 0, P(3), P(7), P(14), pal_primary_,
                  WithOpacity(pal_primary_, 0.24), 0, pal_primary_);
      hits.push_back(Hit{"rightVolume", area, -1});
    } else {
      const bool src = it.id.rfind("source:", 0) == 0;
      double font = src ? 13 : 15;
      if (first_pill && !src) {
        font = land_ ? 12 : 14;
        first_pill = false;
      }
      PaintAppPill(cv, rc, it.label, it.sub, font, it.selected);
      hits.push_back(Hit{"right:" + it.id, rc, static_cast<int>(i)});
    }
  }
  cv.ClearClip();
}

// 直播底部频道信息条（dialogBg 圆角 10，内边距 16/12）。
void Win7ChromeShell::PaintChannel(Canvas& cv) {
  const int W = cv.width();
  const int H = cv.height();
  cv.RoundRect(R(0, 0, W, H), static_cast<float>(P(10)), pal_dialog_bg_);
  int x = P(16);
  const int num_w = static_cast<int>(std::clamp(20 * 0.62 * std::clamp(static_cast<int>(channel_no_.size()), 3, 8) + 10.0, 40.0, 120.0) * grow_ * dpr_);
  cv.Text(R(x, 0, x + num_w, H), channel_no_, pal_muted_, F(20), 400, DT_LEFT | DT_VCENTER | DT_SINGLELINE);
  x += num_w + P(12);
  const RECT logo = R(x, H / 2 - P(18), x + P(48), H / 2 + P(18));
  std::wstring s = channel_name_;
  while (!s.empty() && s.front() == L' ') s.erase(s.begin());
  if (!s.empty() && s.front() == L'\x2605') s.erase(s.begin());
  while (!s.empty() && s.front() == L' ') s.erase(s.begin());
  const std::wstring letter = s.empty() ? L"！" : s.substr(0, (s.size() > 1 && IS_HIGH_SURROGATE(s[0])) ? 2 : 1);
  static const Argb kLogo[] = {0xFFE53935, 0xFFD81B60, 0xFF8E24AA, 0xFF5E35B1, 0xFF3949AB, 0xFF1E88E5,
                               0xFF039BE5, 0xFF00ACC1, 0xFF00897B, 0xFF43A047, 0xFF7CB342, 0xFFC0CA33,
                               0xFFFB8C00, 0xFFF4511E, 0xFF6D4C41, 0xFF546E7A};
  unsigned int hcode = 0;
  for (wchar_t wc : letter) hcode = 31 * hcode + static_cast<unsigned int>(wc);
  cv.RoundRect(logo, static_cast<float>(P(4)), kLogo[hcode % 16]);
  cv.Text(logo, letter, kWhite, F(12), 600, kCenterFmt);
  x += P(48) + P(8);
  int right = W - P(16);
  if (!line_label_.empty()) {
    const int lw = std::min(cv.Measure(line_label_, F(13), 400), (right - x) / 3);
    cv.Text(R(right - lw, 0, right, H), line_label_, pal_muted_, F(13), 400, kRight | DT_END_ELLIPSIS);
    right -= lw + P(8);
  }
  const int th = cv.LineHeight(F(18), 600);
  const int sh = cv.LineHeight(F(13), 400);
  const bool second = !prog_time_.empty() || !prog_title_.empty();
  const int ty = second ? H / 2 - (th + sh) / 2 : H / 2 - th / 2;
  cv.Text(R(x, ty, right, ty + th), channel_name_, pal_fg_, F(18), 600, kLeft);
  if (second) {
    int sx = x;
    if (!prog_time_.empty()) {
      sx += cv.Text(R(sx, ty + th, right, ty + th + sh), prog_time_, pal_muted_, F(12), 400, kLeft) + P(6);
    }
    cv.Text(R(sx, ty + th, right, ty + th + sh), prog_title_, pal_muted_, F(13), 400, kLeft);
  }
}

// 回看「返回直播 / 退出全屏」AppPill。
void Win7ChromeShell::PaintPill(Canvas& cv, std::vector<Hit>& hits) {
  const RECT rc = R(0, 0, cv.width(), cv.height());
  cv.RoundRect(rc, static_cast<float>(L(8)), pal_pill_bg_, pal_pill_border_, 1.0f);
  cv.Text(R(L(6), 0, rc.right - L(6), rc.bottom), pill_label_, pal_fg_, FL(land_ ? 12 : 14), 700, kCenterFmt);
  hits.push_back(Hit{"pill", rc, -1});
}

// ---------------------------------------------------------------------------
// 弹层（_chromeSheetFrame / 更多 / 倍速 / 调色 / 音效 / 轨道 / 播放信息 …）
// ---------------------------------------------------------------------------

int Win7ChromeShell::SheetLayout(Canvas* cv, std::vector<Hit>* hits, const RECT& card, int scroll) {
  static Canvas measure;
  Canvas& m = cv ? *cv : measure;
  const bool more = sheet_kind_ == "more";
  const int inset = G(4);
  const int left = card.left + inset;
  const int right = card.right - inset;
  int y = card.top + G(10) - scroll;
  auto visible = [&](int top, int h) { return top + h >= card.top && top <= card.bottom; };
  auto hit = [&](const char* id, RECT rc, int index) {
    if (!hits) return;
    IntersectRect(&rc, &rc, &card);
    if (rc.right > rc.left && rc.bottom > rc.top) hits->push_back(Hit{id, rc, index});
  };
  // 拖手
  if (cv) {
    const int hx = (card.left + card.right) / 2;
    cv->RoundRect(R(hx - G(20), y, hx + G(20), y + G(4)), static_cast<float>(G(2)), WithOpacity(kWhite, 0.28));
  }
  y += G(4) + G(10);
  if (!more && !sheet_title_.empty()) {
    y += G(4);
    const int th = m.LineHeight(F(17), 700);
    if (cv) cv->Text(R(card.left + G(16), y, card.right - G(16), y + th), sheet_title_, kWhite, F(17), 700, kLeft);
    y += th;
    if (!sheet_subtitle_.empty()) {
      y += G(4);
      const int sh = m.LineHeight(F(13), 400);
      if (cv) cv->Text(R(card.left + G(16), y, card.right - G(16), y + sh), sheet_subtitle_, WithOpacity(kWhite, 0.65), F(13), 400, kLeft);
      y += sh;
    }
    y += G(2) + G(4);
  }

  const int n = static_cast<int>(sheet_items_.size());
  for (int i = 0; i < n; ++i) {
    LineItem& it = sheet_items_[i];
    const std::string& k = it.kind;
    if (k == "chip" || k == "action") {
      // Wrap：_EqPresetChip（右/下 8）或 ActionChip（spacing 8）
      const bool action = k == "action";
      const int pad_l = P(12);
      int x = left + pad_l;
      const int max_x = right - P(12);
      y += action ? 0 : P(4);
      int row_h = 0;
      int j = i;
      for (; j < n && sheet_items_[j].kind == k; ++j) {
        LineItem& c = sheet_items_[j];
        const float fs = action ? F(14) : F(13);
        const int weight = action ? 500 : 600;
        const int tw = m.Measure(c.label, fs, weight);
        const int check = (!action && c.selected) ? P(16) + P(4) : 0;
        const int w = action ? tw + P(8) * 2 + P(2) : tw + check + P(12) * 2;
        const int h = action ? P(32) : m.LineHeight(fs, weight) + P(8) * 2;
        if (x + w > max_x && x > left + pad_l) {
          x = left + pad_l;
          y += row_h + P(8);
          row_h = 0;
        }
        const RECT rc = R(x, y, x + w, y + h);
        if (cv && visible(rc.top, h)) {
          if (action) {
            cv->RoundRect(rc, static_cast<float>(P(8)), 0, 0xFF938F99, 1.0f);
            cv->Text(rc, c.label, kWhite, fs, weight, kCenterFmt);
          } else {
            cv->RoundRect(rc, static_cast<float>(P(20)), c.selected ? kWhite : 0xFF3A3A42);
            int cx = rc.left + P(12);
            if (c.selected) {
              cv->Icon(R(cx, rc.top, cx + P(16), rc.bottom), ic::kCheck, static_cast<float>(P(16)), 0xDE000000);
              cx += P(16) + P(4);
            }
            cv->Text(R(cx, rc.top, rc.right - P(12), rc.bottom), c.label,
                     c.selected ? 0xDE000000 : WithOpacity(kWhite, 0.92), fs, weight, kLeft);
          }
        }
        hit("sheetTap", rc, j);
        row_h = std::max(row_h, h);
        x += w + P(8);
      }
      y += row_h + (action ? P(12) : P(8));
      i = j - 1;
      continue;
    }
    if (k == "hold" || k == "button") {
      int j = i;
      while (j < n && (sheet_items_[j].kind == "hold" || sheet_items_[j].kind == "button")) ++j;
      const int count = j - i;
      y += P(8);
      const int h = m.LineHeight(F(13), 400) + P(10) * 2;
      const int avail = right - left - P(12) * 2 - P(8) * (count - 1);
      int x = left + P(12);
      for (int q = i; q < j; ++q) {
        const LineItem& b = sheet_items_[q];
        const int w = avail / count;
        const RECT rc = R(x, y, x + w, y + h);
        const bool held = b.kind == "hold" && hold_btn_down_;
        if (cv && visible(rc.top, h)) {
          cv->RoundRect(rc, static_cast<float>(P(8)), held ? kWhite : 0, held ? kWhite : kWhite38, 1.0f);
          cv->Text(rc, b.label, held ? 0xDE000000 : 0xB3FFFFFF, F(13), 400, kCenterFmt);
        }
        hit(b.kind == "hold" ? "sheetHold" : "sheetTap", rc, q);
        x += w + P(8);
      }
      y += h + P(4);
      i = j - 1;
      continue;
    }
    if (k == "header") {
      const int pt = G(it.on ? 16 : 12);
      const int h = m.LineHeight(F(13), 400);
      if (cv && visible(y, pt + h + G(4)))
        cv->Text(R(left + G(16), y + pt, right - G(16), y + pt + h), it.label, WithOpacity(kWhite, 0.55), F(13), 400, kLeft);
      y += pt + h + G(4);
      continue;
    }
    if (k == "info") {
      const int h = m.LineHeight(F(15), 400);
      if (cv && visible(y, h + G(20)))
        cv->Text(R(left + G(16), y + G(8), right - G(16), y + G(8) + h), it.label, WithOpacity(kWhite, 0.55), F(15), 400, kLeft);
      y += G(8) + h + G(12);
      continue;
    }
    if (k == "text") {
      const int lh = static_cast<int>(F(15) * 1.55f);
      y += G(8);
      size_t s = 0;
      const std::wstring& t = it.label;
      while (s <= t.size()) {
        size_t e = t.find(L'\n', s);
        if (e == std::wstring::npos) e = t.size();
        if (cv && visible(y, lh))
          cv->Text(R(left + G(16), y, right - G(16), y + lh), t.substr(s, e - s), WithOpacity(kWhite, 0.75), F(15), 400, kLeft);
        y += lh;
        s = e + 1;
      }
      y += G(8);
      continue;
    }
    if (k == "big") {
      const int h = m.LineHeight(F(28), 700);
      y += P(8);
      if (cv && visible(y, h)) cv->Text(R(left + P(16), y, right - P(16), y + h), it.label, kWhite, F(28), 700, kCenterFmt);
      y += h + P(4);
      continue;
    }
    if (k == "slider" || k == "sliderInline") {
      const bool inl = k == "sliderInline";
      const double frac = it.slider_max > it.slider_min
                              ? (it.slider_value - it.slider_min) / (it.slider_max - it.slider_min)
                              : 0;
      if (inl) {
        // KotvStepSlider(inline)：左 72 宽标签 13 号 white70；默认 Slider（轨 4、拇指 10、高 48）。
        const int h = P(48);
        int sx = left + P(12);
        if (!it.label.empty()) {
          if (cv && visible(y, h)) cv->Text(R(sx, y, sx + P(72), y + h), it.label, 0xB3FFFFFF, F(13), 400, kLeft);
          sx += P(72);
        }
        const RECT area = R(sx, y, right - P(12), y + h);
        if (cv && visible(y, h))
          PaintSlider(*cv, area, frac, 0, P(4), P(10), P(24), pal_primary_, WithOpacity(pal_primary_, 0.24), 0, pal_primary_);
        hit("sheetSlider", area, i);
        y += h + P(4);
      } else {
        // KotvStepSlider：标签 14 w500 + 数值 13 muted；轨 3、拇指 7、overlay 14。
        y += P(8);
        const int lh = m.LineHeight(F(14), 500);
        if (cv && visible(y, lh)) {
          cv->Text(R(left + P(16), y, right - P(16), y + lh), it.label, pal_fg_, F(14), 500, kLeft);
          cv->Text(R(left + P(16), y, right - P(16), y + lh), it.trailing, pal_muted_, F(13), 400, kRight);
        }
        y += lh;
        const RECT area = R(left + P(16), y, right - P(16), y + P(28));
        if (cv && visible(y, P(28)))
          PaintSlider(*cv, area, frac, 0, P(3), P(7), P(14), pal_primary_, WithOpacity(pal_primary_, 0.24), 0, pal_primary_);
        hit("sheetSlider", area, i);
        y += P(28) + P(4);
      }
      continue;
    }
    if (k == "toggle" || k == "switch") {
      // 更多里的开关行：(8,2) 外边距，52 高；SwitchListTile：56 高，激活 E52D27。
      const bool sw_tile = k == "switch";
      const int h = sw_tile ? P(56) : P(52);
      const int top = y + (sw_tile ? 0 : P(2));
      const RECT row = R(left + (sw_tile ? 0 : P(8)), top, right - (sw_tile ? 0 : P(8)), top + h);
      if (cv && visible(row.top, h)) {
        int x = row.left + (sw_tile ? P(12) : P(8));
        const uint32_t cp = kotv_chrome::IconByName(it.icon);
        if (cp && !sw_tile) {
          cv->Icon(R(x, row.top, x + P(24), row.bottom), cp, static_cast<float>(P(24)), kWhite);
          x += P(24) + P(16);
        }
        const int sw_w = P(52);
        const int sw_h = P(32);
        const int sx = row.right - (sw_tile ? P(12) : P(4)) - sw_w;
        cv->Text(R(x, row.top, sx - P(8), row.bottom), it.label, kWhite, F(16), 500, kLeft);
        const int sy = (row.top + row.bottom) / 2 - sw_h / 2;
        const Argb track = it.on ? (sw_tile ? kAccent : 0xFF5C5C66) : 0xFF3A3A42;
        cv->RoundRect(R(sx, sy, sx + sw_w, sy + sw_h), sw_h / 2.0f, track);
        const float tr = it.on ? P(12) : P(8);
        const float tcx = it.on ? sx + sw_w - P(16) : sx + P(16);
        cv->Circle(tcx, sy + sw_h / 2.0f, tr, it.on ? kWhite : 0xFFB0B0B8);
      }
      hit("sheetTap", row, i);
      y += h + (sw_tile ? 0 : P(4));
      continue;
    }
    if (k == "link" || k == "cycle") {
      const int h = P(52);
      const RECT row = R(left, y, right, y + h);
      if (cv && visible(y, h)) {
        int x = row.left + P(16);
        const uint32_t cp = kotv_chrome::IconByName(it.icon);
        if (cp) {
          cv->Icon(R(x, row.top, x + P(24), row.bottom), cp, static_cast<float>(P(24)), kWhite);
          x += P(24) + P(16);
        }
        int r = row.right - P(16);
        if (it.chevron) {
          cv->Icon(R(r - P(22), row.top, r, row.bottom), ic::kChevronRight, static_cast<float>(P(22)),
                   WithOpacity(kWhite, 0.45));
          r -= P(22);
        }
        if (!it.trailing.empty()) {
          const int tw = cv->Measure(it.trailing, F(15), 400);
          cv->Text(R(r - tw, row.top, r, row.bottom), it.trailing, WithOpacity(kWhite, 0.55), F(15), 400, kRight);
          r -= tw + P(8);
        }
        cv->Text(R(x, row.top, r, row.bottom), it.label, kWhite, F(16), 500, kLeft);
      }
      hit("sheetTap", row, i);
      y += h;
      continue;
    }
    // _chromeSelectRow：52*ui，图标 24*ui，选中 w700 + check 22*ui。
    const int h = G(52);
    const RECT row = R(left, y, right, y + h);
    const bool sel = it.selected || it.trailing == L"\x2713";
    if (cv && visible(y, h)) {
      int x = row.left + G(16);
      const uint32_t cp = kotv_chrome::IconByName(it.icon);
      if (cp) {
        cv->Icon(R(x, row.top, x + G(24), row.bottom), cp, static_cast<float>(G(24)), kWhite);
        x += G(24) + G(16);
      }
      int r = row.right - G(16);
      if (sel) {
        cv->Icon(R(r - G(22), row.top, r, row.bottom), ic::kCheck, static_cast<float>(G(22)), kWhite);
        r -= G(22) + G(8);
      }
      cv->Text(R(x, row.top, r, row.bottom), it.label, kWhite, F(16), sel ? 700 : 500, kLeft);
    }
    hit("sheetTap", row, i);
    y += h;
  }
  y += G(12);
  return y + scroll - card.top;
}

void Win7ChromeShell::PaintSheet(Canvas& cv, std::vector<Hit>& hits) {
  const int W = cv.width();
  const int H = cv.height();
  cv.Fill(R(0, 0, W, H), 0x61000000);
  const int margin = G(12);
  const int sheet_w = std::min(W, P(640));
  const int card_w = sheet_w - margin * 2;
  const int x0 = (W - sheet_w) / 2 + margin;
  const int content = SheetLayout(nullptr, nullptr, R(x0, 0, x0 + card_w, 100000), 0);
  const int card_h = std::min(content, static_cast<int>(H * 0.72));
  sheet_card_ = R(x0, H - margin - card_h, x0 + card_w, H - margin);
  sheet_content_h_ = content;
  sheet_scroll_ = std::clamp(sheet_scroll_, 0, std::max(0, content - card_h));
  cv.RoundRect(sheet_card_, static_cast<float>(G(18)), 0xCC2A2A30);
  cv.SetClip(sheet_card_);
  SheetLayout(&cv, &hits, sheet_card_, sheet_scroll_);
  cv.ClearClip();
}

// KotvFullscreenExpandButton 菜单：锚在全屏钮上方 8。
void Win7ChromeShell::PaintPopup(Canvas& cv, std::vector<Hit>& hits) {
  const int W = cv.width();
  const int H = cv.height();
  cv.Fill(R(0, 0, W, H), 0x01000000);
  const float fs = F(13);
  const int pad_h = G(14);
  const int pad_v = G(11);
  const int icon = G(18);
  const int gap = G(10);
  const int lh = cv.LineHeight(fs, 700);
  const int item_h = std::max(icon, lh) + pad_v * 2;
  const int tw = std::max(cv.Measure(L"铺满当前窗口", fs, 700), cv.Measure(L"占满整块屏幕", fs, 700));
  const int w = pad_h * 2 + icon + gap + tw;
  const int h = item_h * 2 + P(1);
  const int cx = (popup_anchor_.left + popup_anchor_.right) / 2;
  int left = std::clamp(cx - w / 2, 0, std::max(0, W - w));
  int top = std::max(0, static_cast<int>(popup_anchor_.top) - P(8) - h);
  const RECT card = R(left, top, left + w, top + h);
  cv.RoundRect(R(card.left, card.top + P(8), card.right, card.bottom + P(8)), static_cast<float>(P(12) + P(9)), 0x22000000);
  cv.RoundRect(card, static_cast<float>(P(12)), 0xF214101C, WithOpacity(kWhite, 0.14), 1.0f);
  struct Item {
    const char* id;
    uint32_t cp;
    const wchar_t* label;
  };
  const Item items[] = {{"window", 0xf683, L"铺满当前窗口"}, {"display", 0xf7a6, L"占满整块屏幕"}};
  int y = card.top;
  for (int i = 0; i < 2; ++i) {
    const RECT row = R(card.left, y, card.right, y + item_h);
    cv.Icon(R(row.left + pad_h, row.top, row.left + pad_h + icon, row.bottom), items[i].cp, static_cast<float>(icon),
            WithOpacity(kWhite, 0.92));
    cv.Text(R(row.left + pad_h + icon + gap, row.top, row.right - pad_h, row.bottom), items[i].label,
            WithOpacity(kWhite, 0.95), fs, 700, kLeft);
    hits.push_back(Hit{items[i].id, row, i});
    y += item_h;
    if (i == 0) {
      cv.Fill(R(card.left, y, card.right, y + P(1)), WithOpacity(kWhite, 0.08));
      y += P(1);
    }
  }
}

// ---------------------------------------------------------------------------
// 弹幕（独立分层 popup，点击穿透）
// ---------------------------------------------------------------------------

void Win7ChromeShell::PaintDanmaku() {
  if (!danmaku_hwnd_) return;
  const RECT box = VideoArea();
  const int W = box.right - box.left;
  const int H = box.bottom - box.top;
  if (W <= 0 || H <= 0) return;
  if (!danmaku_canvas_) danmaku_canvas_ = std::make_unique<Canvas>();
  double pos = position_sec_;
  if (playing_ && position_tick_) pos += (GetTickCount() - position_tick_) / 1000.0 * rate_;
  const float fs = static_cast<float>(danmaku_font_ * dpr_);
  const int weight = danmaku_bold_ ? 700 : 400;
  std::vector<size_t> live;
  const double max_age = std::max(danmaku_duration_ms_, danmaku_fixed_ms_) / 1000.0 + 0.2;
  auto lo = std::lower_bound(danmaku_items_.begin(), danmaku_items_.end(), pos - max_age,
                             [](const DanmakuItem& d, double t) { return d.time < t; });
  for (auto it = lo; it != danmaku_items_.end() && it->time <= pos + 0.05; ++it) {
    const auto& d = *it;
    const bool scroll = d.mode == 1 || d.mode == 2 || d.mode == 3 || d.mode == 6;
    const bool top = d.mode == 5;
    const bool bottom = d.mode == 4;
    const bool positioned = d.mode == 7;
    const bool special = d.mode >= 8;
    if (scroll && d.mode != 6 && !danmaku_show_scroll_) continue;
    if (d.mode == 6 && !danmaku_show_reverse_) continue;
    if (top && !danmaku_show_top_) continue;
    if (bottom && !danmaku_show_bottom_) continue;
    if (positioned && !danmaku_show_positioned_) continue;
    if (special) continue;
    const double age = pos - d.time;
    const int dur = (scroll ? danmaku_duration_ms_ : danmaku_fixed_ms_);
    if (age < 0 || age * 1000.0 > dur) continue;
    live.push_back(static_cast<size_t>(it - danmaku_items_.begin()));
    if (static_cast<int>(live.size()) >= danmaku_max_on_screen_) break;
  }
  if (live.empty() && danmaku_painted_empty_) return;
  Canvas& cv = *danmaku_canvas_;
  if (!cv.Begin(W, H)) return;
  const int row_h = static_cast<int>(fs * 1.3f);
  const int area_rows = std::max(1, static_cast<int>(H * danmaku_scroll_area_) / std::max(1, row_h));
  const int rows = std::max(1, std::min(danmaku_rows_, area_rows));
  const Argb alpha = static_cast<Argb>(std::lround(danmaku_opacity_ * 255)) << 24;
  const Argb shadow = static_cast<Argb>(std::lround(danmaku_opacity_ * 0.6 * 255)) << 24;
  for (size_t idx : live) {
    const auto& d = danmaku_items_[idx];
    const bool scroll = d.mode == 1 || d.mode == 2 || d.mode == 3 || d.mode == 6;
    const bool bottom = d.mode == 4;
    const int row = static_cast<int>(idx % static_cast<size_t>(rows));
    const int y = bottom ? H - (row + 1) * row_h - P(8) : P(8) + row * row_h;
    const int tw = cv.Measure(d.content, fs, weight);
    int x = (W - tw) / 2;
    if (scroll) {
      const double t = std::clamp((pos - d.time) * 1000.0 / danmaku_duration_ms_, 0.0, 1.0);
      x = d.mode == 6 ? static_cast<int>(-tw + t * (W + tw)) : static_cast<int>(W - t * (W + tw));
    }
    if (x + tw < 0 || x > W) continue;
    const RECT rc = R(std::max(0, x), y, std::min(W, x + tw + P(2)), y + row_h);
    if (rc.right <= rc.left) continue;
    const UINT fmt = DT_SINGLELINE | DT_VCENTER | DT_NOCLIP | (x < 0 ? DT_RIGHT : DT_LEFT);
    RECT sh = rc;
    OffsetRect(&sh, P(1), P(1));
    cv.Text(sh, d.content, shadow, fs, weight, fmt);
    cv.Text(rc, d.content, alpha | (static_cast<Argb>(d.color) & 0xFFFFFF), fs, weight, fmt);
  }
  cv.End();
  POINT pt{box.left, box.top};
  ClientToScreen(host_hwnd_, &pt);
  kotv_chrome::PresentLayered(danmaku_hwnd_, cv, pt.x, pt.y);
  danmaku_painted_empty_ = live.empty();
}
