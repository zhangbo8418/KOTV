#include "win7_chrome_shell.h"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <memory>
#include <sstream>
#include <string>
#include <utility>
#include <vector>


#include <windowsx.h>
#include <commctrl.h>
#pragma comment(lib, "comctl32.lib")

#include <gdiplus.h>

using namespace Gdiplus;

namespace {

constexpr wchar_t kClass[] = L"KotvWinChromePanel";
constexpr wchar_t kDanmakuClass[] = L"KotvWinChromeDanmaku";
constexpr wchar_t kModalClass[] = L"KotvWinChromeModal";
constexpr wchar_t kGestureClass[] = L"KotvWinChromeGesture";
constexpr int kTopH = 56;
constexpr int kBottomH = 128;       // 全屏：时钟 + 进度 + 动作行（对齐 Flutter）
constexpr int kInlineBottomH = 72;  // 内嵌：动作行 + 进度
constexpr int kEpW = 280;
constexpr int kLiveRightW = 220;
constexpr int kChannelH = 56;
constexpr int kLiveGroupW = 112;
constexpr int kLiveChannelW = 248;
constexpr int kLiveEpgTabW = 28;
constexpr int kLiveEpgW = 220;
constexpr int kLivePad = 8;
constexpr int kCenterSz = 72;
constexpr int kModalW = 360;
constexpr int kModalMaxH = 560;
constexpr int kModalMoreW = 420;
constexpr COLORREF kPink = RGB(229, 45, 39);       // #E52D27（全屏等旧强调）
constexpr COLORREF kPrimary = RGB(207, 66, 116);   // #CF4274 = KotvColors.primary
constexpr COLORREF kPinkMuted = RGB(180, 90, 110);
constexpr BYTE kInlineBarAlpha = 204;             // 0xCC ≈ VodInlineControls 0xCC0A0A12
constexpr BYTE kFsTopBarAlpha = 0x66;             // VodFullscreenChrome 顶栏 0x66000000
constexpr BYTE kFsBottomBarAlpha = 0x99;          // VodFullscreenChrome 底栏 0x99000000
constexpr COLORREF kPanelDark = RGB(18, 10, 28);    // #120A1C
constexpr COLORREF kBarDark = RGB(12, 8, 18);
constexpr COLORREF kBarAlpha = RGB(28, 20, 36);
constexpr COLORREF kDanmakuKey = RGB(1, 0, 1);
constexpr COLORREF kSheetLight = RGB(248, 246, 250);
constexpr COLORREF kSheetDark = RGB(42, 42, 48);    // 0xCC2A2A30 近似
constexpr COLORREF kGreenOn = RGB(52, 199, 89);
constexpr UINT_PTR kSubclassIdHost = 0x4B4F5456;  // 'KOTV'
constexpr UINT_PTR kSubclassIdRoot = 0x4B4F5457;
constexpr UINT_PTR kHoldSpeedTimerId = 42;
constexpr UINT_PTR kEpisodesCloseTimerId = 43;
constexpr DWORD kHoldSpeedMs = 450;
constexpr DWORD kEpisodesCloseMs = 5000;  // kotvPlayerOverlayHide
constexpr int kGestureSlop = 8;
constexpr int kDesktopEdgeHover = 16;
constexpr int kEdgeIgnore = 24;
constexpr double kSeekMsPerPx = 50.0;
constexpr int kSheetPad = 12;
constexpr int kSheetRadius = 18;
constexpr int kRowIconSz = 24;
constexpr int kListRowH = 52;

std::wstring Utf8ToWide(const std::string& utf8) {
  if (utf8.empty()) return {};
  int n = MultiByteToWideChar(CP_UTF8, 0, utf8.c_str(), -1, nullptr, 0);
  if (n <= 1) return {};
  std::wstring out(static_cast<size_t>(n - 1), L'\0');
  MultiByteToWideChar(CP_UTF8, 0, utf8.c_str(), -1, &out[0], n);
  return out;
}

using ChromeMap = Win7ChromeShell::ChromeMap;
using ChromeValue = Win7ChromeShell::ChromeValue;


std::string GetString(const ChromeMap& m, const char* key) {
  const auto it = m.find(key);
  if (it == m.end() || !std::holds_alternative<std::string>(it->second)) return {};
  return std::get<std::string>(it->second);
}

bool GetBool(const ChromeMap& m, const char* key, bool def = false) {
  const auto it = m.find(key);
  if (it == m.end() || !std::holds_alternative<bool>(it->second)) return def;
  return std::get<bool>(it->second);
}

double GetDouble(const ChromeMap& m, const char* key, double def = 0) {
  const auto it = m.find(key);
  if (it == m.end()) return def;
  if (std::holds_alternative<double>(it->second)) return std::get<double>(it->second);
  if (std::holds_alternative<int64_t>(it->second)) return static_cast<double>(std::get<int64_t>(it->second));
  if (std::holds_alternative<bool>(it->second)) return std::get<bool>(it->second) ? 1.0 : 0.0;
  return def;
}

int GetInt(const ChromeMap& m, const char* key, int def = 0) {
  return static_cast<int>(GetDouble(m, key, def));
}

bool HasKey(const ChromeMap& m, const char* key) { return m.find(key) != m.end(); }

std::vector<std::wstring> GetStringList(const ChromeMap& m, const char* key) {
  // 列表以换行拼接的字符串传入（适配层约定）。
  std::vector<std::wstring> out;
  const auto s = GetString(m, key);
  if (s.empty()) return out;
  size_t start = 0;
  while (start <= s.size()) {
    size_t p = s.find('\n', start);
    if (p == std::string::npos) {
      out.push_back(Utf8ToWide(s.substr(start)));
      break;
    }
    out.push_back(Utf8ToWide(s.substr(start, p - start)));
    start = p + 1;
  }
  return out;
}

std::vector<std::string> GetUtf8List(const ChromeMap& m, const char* key) {
  std::vector<std::string> out;
  const auto s = GetString(m, key);
  if (s.empty()) return out;
  size_t start = 0;
  while (start <= s.size()) {
    size_t p = s.find('\n', start);
    if (p == std::string::npos) {
      out.push_back(s.substr(start));
      break;
    }
    out.push_back(s.substr(start, p - start));
    start = p + 1;
  }
  return out;
}

std::vector<Win7ChromeShell::LineItem> ParseLineItems(const ChromeMap& m, const char* key) {
  // 适配层约定：每行 id|label|trailing|toggle|on|chevron|slider|min|max|value
  std::vector<Win7ChromeShell::LineItem> out;
  const auto blob = GetString(m, key);
  if (blob.empty()) return out;
  size_t start = 0;
  while (start < blob.size()) {
    size_t p = blob.find('\n', start);
    std::string line = p == std::string::npos ? blob.substr(start) : blob.substr(start, p - start);
    if (p == std::string::npos) start = blob.size(); else start = p + 1;
    if (line.empty()) continue;
    std::vector<std::string> cols;
    size_t cs = 0;
    while (cs <= line.size()) {
      size_t c = line.find('|', cs);
      if (c == std::string::npos) { cols.push_back(line.substr(cs)); break; }
      cols.push_back(line.substr(cs, c - cs));
      cs = c + 1;
    }
    while (cols.size() < 10) cols.push_back("");
    Win7ChromeShell::LineItem item;
    item.id = cols[0];
    item.label = Utf8ToWide(cols[1]);
    item.trailing = Utf8ToWide(cols[2]);
    item.toggle = cols[3] == "1";
    item.on = cols[4] == "1";
    item.chevron = cols[5] == "1";
    item.slider = cols[6] == "1";
    item.slider_min = cols[7].empty() ? 0 : std::strtod(cols[7].c_str(), nullptr);
    item.slider_max = cols[8].empty() ? 100 : std::strtod(cols[8].c_str(), nullptr);
    item.slider_value = cols[9].empty() ? 0 : std::strtod(cols[9].c_str(), nullptr);
    out.push_back(std::move(item));
  }
  return out;
}

Color ToGdip(COLORREF c, BYTE alpha = 255) {
  return Color(alpha, GetRValue(c), GetGValue(c), GetBValue(c));
}

void FillRectColor(HDC hdc, const RECT& rc, COLORREF c) {
  Graphics g(hdc);
  g.SetSmoothingMode(Gdiplus::SmoothingModeNone);
  SolidBrush br(ToGdip(c));
  g.FillRectangle(&br, static_cast<INT>(rc.left), static_cast<INT>(rc.top),
                  static_cast<INT>(rc.right - rc.left), static_cast<INT>(rc.bottom - rc.top));
}

void AddRoundRectPath(GraphicsPath* path, const RECT& rc, int radius) {
  const float x = static_cast<float>(rc.left);
  const float y = static_cast<float>(rc.top);
  const float w = static_cast<float>(rc.right - rc.left);
  const float h = static_cast<float>(rc.bottom - rc.top);
  const float r = static_cast<float>(std::max(0, radius));
  if (r <= 0.5f || w < 2 * r || h < 2 * r) {
    path->AddRectangle(RectF(x, y, w, h));
    return;
  }
  const float d = r * 2.f;
  path->AddArc(x, y, d, d, 180.f, 90.f);
  path->AddArc(x + w - d, y, d, d, 270.f, 90.f);
  path->AddArc(x + w - d, y + h - d, d, d, 0.f, 90.f);
  path->AddArc(x, y + h - d, d, d, 90.f, 90.f);
  path->CloseFigure();
}

void FillRoundRect(HDC hdc, const RECT& rc, int radius, COLORREF fill, COLORREF border = 0,
                   int border_w = 0) {
  Graphics g(hdc);
  g.SetSmoothingMode(Gdiplus::SmoothingModeAntiAlias);
  GraphicsPath path;
  AddRoundRectPath(&path, rc, radius);
  SolidBrush br(ToGdip(fill));
  g.FillPath(&br, &path);
  if (border_w > 0) {
    Pen pen(ToGdip(border), static_cast<Gdiplus::REAL>(border_w));
    g.DrawPath(&pen, &path);
  }
}

void DrawTextLine(HDC hdc, const RECT& rc, const std::wstring& text, COLORREF color, int px,
                  bool bold = false, UINT align = DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS) {
  if (text.empty()) return;
  Graphics g(hdc);
  g.SetTextRenderingHint(Gdiplus::TextRenderingHintClearTypeGridFit);
  g.SetSmoothingMode(Gdiplus::SmoothingModeAntiAlias);
  std::unique_ptr<FontFamily> family(new FontFamily(L"Microsoft YaHei UI"));
  if (family->GetLastStatus() != Gdiplus::Ok) {
    family.reset(new FontFamily(L"Microsoft YaHei"));
  }
  if (family->GetLastStatus() != Gdiplus::Ok) {
    family.reset(new FontFamily(L"Segoe UI"));
  }
  Font font(family.get(), static_cast<Gdiplus::REAL>(px), bold ? FontStyleBold : FontStyleRegular,
            Gdiplus::UnitPixel);
  SolidBrush brush(ToGdip(color));
  StringFormat fmt;
  fmt.SetTrimming(StringTrimmingEllipsisCharacter);
  fmt.SetFormatFlags(StringFormatFlagsNoWrap);
  if (align & DT_CENTER) fmt.SetAlignment(StringAlignmentCenter);
  else if (align & DT_RIGHT) fmt.SetAlignment(StringAlignmentFar);
  else fmt.SetAlignment(StringAlignmentNear);
  if (align & DT_VCENTER) fmt.SetLineAlignment(StringAlignmentCenter);
  else if (align & DT_BOTTOM) fmt.SetLineAlignment(StringAlignmentFar);
  else fmt.SetLineAlignment(StringAlignmentNear);
  RectF layout(static_cast<Gdiplus::REAL>(rc.left), static_cast<Gdiplus::REAL>(rc.top),
               static_cast<Gdiplus::REAL>(std::max(0L, rc.right - rc.left)),
               static_cast<Gdiplus::REAL>(std::max(0L, rc.bottom - rc.top)));
  g.DrawString(text.c_str(), -1, &font, layout, &fmt, &brush);
}

COLORREF Blend(COLORREF a, COLORREF b, double t) {
  auto ch = [&](int shift) {
    const int ca = (a >> shift) & 0xFF;
    const int cb = (b >> shift) & 0xFF;
    return static_cast<int>(ca + (cb - ca) * t);
  };
  return RGB(ch(0), ch(8), ch(16));
}

RectF InsetBox(const RECT& rc, float pad) {
  return RectF(static_cast<REAL>(rc.left) + pad, static_cast<REAL>(rc.top) + pad,
               static_cast<REAL>(rc.right - rc.left) - pad * 2.f,
               static_cast<REAL>(rc.bottom - rc.top) - pad * 2.f);
}

// 几何图标（避免 Win7 缺 emoji/Material 字体）
enum class ChromeIcon {
  Play,
  Pause,
  Stop,
  Prev,
  Next,
  Cast,
  Pip,
  Expand,
  Replay,
  Speed,
  Aspect,
  Decode,
  Cc,
  Audio,
  Video,
  Devices,
  Volume,
  DirectOn,
  DirectOff,
  CloseFs,
};

void DrawChromeIcon(HDC hdc, const RECT& rc, ChromeIcon kind, COLORREF color) {
  Graphics g(hdc);
  g.SetSmoothingMode(SmoothingModeAntiAlias);
  const Color c = ToGdip(color);
  Pen pen(c, 1.8f);
  SolidBrush br(c);
  const int side = std::max(1L, std::min(rc.right - rc.left, rc.bottom - rc.top));
  const float pad = std::clamp(side * 0.18f, 3.f, 8.f);
  const RectF box = InsetBox(rc, pad);
  const REAL cx = box.X + box.Width / 2.f;
  const REAL cy = box.Y + box.Height / 2.f;
  const REAL s = (std::min)(box.Width, box.Height);

  switch (kind) {
    case ChromeIcon::Play: {
      GraphicsPath p;
      p.AddLine(box.X + s * 0.28f, box.Y + s * 0.15f, box.X + s * 0.28f, box.Y + s * 0.85f);
      p.AddLine(box.X + s * 0.28f, box.Y + s * 0.85f, box.X + s * 0.82f, cy);
      p.CloseFigure();
      g.FillPath(&br, &p);
      break;
    }
    case ChromeIcon::Pause: {
      const REAL w = s * 0.18f;
      const REAL gap = s * 0.14f;
      g.FillRectangle(&br, cx - gap - w, box.Y + s * 0.18f, w, s * 0.64f);
      g.FillRectangle(&br, cx + gap, box.Y + s * 0.18f, w, s * 0.64f);
      break;
    }
    case ChromeIcon::Stop:
      g.FillRectangle(&br, box.X + s * 0.25f, box.Y + s * 0.25f, s * 0.5f, s * 0.5f);
      break;
    case ChromeIcon::Prev:
    case ChromeIcon::Next: {
      const bool next = kind == ChromeIcon::Next;
      GraphicsPath tri;
      if (next) {
        tri.AddLine(box.X + s * 0.22f, box.Y + s * 0.2f, box.X + s * 0.22f, box.Y + s * 0.8f);
        tri.AddLine(box.X + s * 0.22f, box.Y + s * 0.8f, box.X + s * 0.62f, cy);
      } else {
        tri.AddLine(box.X + s * 0.78f, box.Y + s * 0.2f, box.X + s * 0.78f, box.Y + s * 0.8f);
        tri.AddLine(box.X + s * 0.78f, box.Y + s * 0.8f, box.X + s * 0.38f, cy);
      }
      tri.CloseFigure();
      g.FillPath(&br, &tri);
      const REAL bar_x = next ? (box.X + s * 0.68f) : (box.X + s * 0.2f);
      g.FillRectangle(&br, bar_x, box.Y + s * 0.2f, s * 0.1f, s * 0.6f);
      break;
    }
    case ChromeIcon::Cast: {
      g.DrawRectangle(&pen, box.X + s * 0.18f, box.Y + s * 0.22f, s * 0.64f, s * 0.48f);
      g.DrawArc(&pen, box.X + s * 0.18f, box.Y + s * 0.55f, s * 0.45f, s * 0.45f, 180.f, 90.f);
      g.DrawArc(&pen, box.X + s * 0.18f, box.Y + s * 0.42f, s * 0.7f, s * 0.7f, 180.f, 90.f);
      g.FillEllipse(&br, box.X + s * 0.2f, box.Y + s * 0.72f, s * 0.12f, s * 0.12f);
      break;
    }
    case ChromeIcon::Pip: {
      g.DrawRectangle(&pen, box.X + s * 0.15f, box.Y + s * 0.2f, s * 0.7f, s * 0.55f);
      g.FillRectangle(&br, box.X + s * 0.45f, box.Y + s * 0.42f, s * 0.32f, s * 0.26f);
      break;
    }
    case ChromeIcon::Expand: {
      // 四角括号
      const REAL m = s * 0.22f;
      const REAL len = s * 0.22f;
      PointF pts[] = {
          {box.X + m, box.Y + m + len}, {box.X + m, box.Y + m}, {box.X + m + len, box.Y + m},
          {box.X + s - m - len, box.Y + m}, {box.X + s - m, box.Y + m}, {box.X + s - m, box.Y + m + len},
          {box.X + s - m, box.Y + s - m - len}, {box.X + s - m, box.Y + s - m}, {box.X + s - m - len, box.Y + s - m},
          {box.X + m + len, box.Y + s - m}, {box.X + m, box.Y + s - m}, {box.X + m, box.Y + s - m - len},
      };
      g.DrawLines(&pen, pts, 3);
      g.DrawLines(&pen, pts + 3, 3);
      g.DrawLines(&pen, pts + 6, 3);
      g.DrawLines(&pen, pts + 9, 3);
      break;
    }
    case ChromeIcon::Replay: {
      g.DrawArc(&pen, box.X + s * 0.2f, box.Y + s * 0.2f, s * 0.6f, s * 0.6f, 40.f, 260.f);
      PointF arrow[] = {{box.X + s * 0.62f, box.Y + s * 0.18f},
                        {box.X + s * 0.78f, box.Y + s * 0.3f},
                        {box.X + s * 0.58f, box.Y + s * 0.36f}};
      g.FillPolygon(&br, arrow, 3);
      break;
    }
    case ChromeIcon::Speed:
      DrawTextLine(hdc, rc, L"»", color, 14, true, DT_CENTER | DT_VCENTER | DT_SINGLELINE);
      break;
    case ChromeIcon::Aspect:
      g.DrawRectangle(&pen, box.X + s * 0.15f, box.Y + s * 0.28f, s * 0.7f, s * 0.44f);
      g.DrawRectangle(&pen, box.X + s * 0.28f, box.Y + s * 0.22f, s * 0.44f, s * 0.56f);
      break;
    case ChromeIcon::Decode:
      g.DrawRectangle(&pen, box.X + s * 0.22f, box.Y + s * 0.28f, s * 0.56f, s * 0.44f);
      g.DrawLine(&pen, cx - s * 0.12f, cy, cx + s * 0.12f, cy);
      g.DrawLine(&pen, cx, cy - s * 0.12f, cx, cy + s * 0.12f);
      break;
    case ChromeIcon::Cc:
      DrawTextLine(hdc, rc, L"CC", color, 11, true, DT_CENTER | DT_VCENTER | DT_SINGLELINE);
      break;
    case ChromeIcon::Audio: {
      GraphicsPath note;
      note.AddEllipse(box.X + s * 0.18f, box.Y + s * 0.55f, s * 0.28f, s * 0.22f);
      g.FillPath(&br, &note);
      g.FillRectangle(&br, box.X + s * 0.4f, box.Y + s * 0.22f, s * 0.1f, s * 0.45f);
      break;
    }
    case ChromeIcon::Video: {
      g.DrawRectangle(&pen, box.X + s * 0.18f, box.Y + s * 0.3f, s * 0.45f, s * 0.4f);
      PointF cam[] = {{box.X + s * 0.65f, box.Y + s * 0.38f},
                      {box.X + s * 0.85f, box.Y + s * 0.28f},
                      {box.X + s * 0.85f, box.Y + s * 0.72f},
                      {box.X + s * 0.65f, box.Y + s * 0.62f}};
      g.FillPolygon(&br, cam, 4);
      break;
    }
    case ChromeIcon::Devices: {
      g.DrawRectangle(&pen, box.X + s * 0.22f, box.Y + s * 0.2f, s * 0.56f, s * 0.4f);
      g.DrawLine(&pen, box.X + s * 0.35f, box.Y + s * 0.68f, box.X + s * 0.65f, box.Y + s * 0.68f);
      g.DrawLine(&pen, cx, box.Y + s * 0.6f, cx, box.Y + s * 0.68f);
      break;
    }
    case ChromeIcon::Volume: {
      PointF sp[] = {{box.X + s * 0.2f, cy - s * 0.12f},
                     {box.X + s * 0.38f, cy - s * 0.12f},
                     {box.X + s * 0.55f, box.Y + s * 0.22f},
                     {box.X + s * 0.55f, box.Y + s * 0.78f},
                     {box.X + s * 0.38f, cy + s * 0.12f},
                     {box.X + s * 0.2f, cy + s * 0.12f}};
      g.FillPolygon(&br, sp, 6);
      g.DrawArc(&pen, box.X + s * 0.45f, box.Y + s * 0.28f, s * 0.35f, s * 0.44f, -50.f, 100.f);
      break;
    }
    case ChromeIcon::DirectOn:
    case ChromeIcon::DirectOff: {
      // Material Icons flash_on 路径比例（viewport 24）：尖顶→腰切→尾尖
      GraphicsPath bolt;
      PointF pts[] = {
          {cx + s * 0.02f, box.Y + s * 0.02f},
          {cx - s * 0.28f, cy + s * 0.02f},
          {cx - s * 0.06f, cy + s * 0.02f},
          {cx - s * 0.18f, box.Y + s * 0.98f},
          {cx + s * 0.32f, cy - s * 0.12f},
          {cx + s * 0.08f, cy - s * 0.12f},
      };
      bolt.AddPolygon(pts, 6);
      g.FillPath(&br, &bolt);
      if (kind == ChromeIcon::DirectOff) {
        Pen slash(c, (std::max)(1.6f, s * 0.09f));
        slash.SetStartCap(LineCapRound);
        slash.SetEndCap(LineCapRound);
        g.DrawLine(&slash, box.X + s * 0.1f, box.Y + s * 0.86f, box.X + s * 0.9f, box.Y + s * 0.14f);
      }
      break;
    }
    case ChromeIcon::CloseFs: {
      // 还原：外框 + 内缩角
      g.DrawRectangle(&pen, box.X + s * 0.28f, box.Y + s * 0.28f, s * 0.5f, s * 0.5f);
      g.DrawLine(&pen, box.X + s * 0.15f, box.Y + s * 0.4f, box.X + s * 0.15f, box.Y + s * 0.15f);
      g.DrawLine(&pen, box.X + s * 0.15f, box.Y + s * 0.15f, box.X + s * 0.4f, box.Y + s * 0.15f);
      g.DrawLine(&pen, box.X + s * 0.85f, box.Y + s * 0.6f, box.X + s * 0.85f, box.Y + s * 0.85f);
      g.DrawLine(&pen, box.X + s * 0.85f, box.Y + s * 0.85f, box.X + s * 0.6f, box.Y + s * 0.85f);
      break;
    }
  }
}

void DrawRowIcon(HDC hdc, const RECT& rc, Win7ChromeShell::RowIcon kind, COLORREF color) {
  if (kind == Win7ChromeShell::RowIcon::None) return;
  Graphics g(hdc);
  g.SetSmoothingMode(SmoothingModeAntiAlias);
  const Color c = ToGdip(color);
  Pen pen(c, 1.6f);
  SolidBrush br(c);
  const int side = (std::max)(1L, (std::min)(rc.right - rc.left, rc.bottom - rc.top));
  const RectF box = InsetBox(rc, (std::clamp)(side * 0.12f, 2.f, 5.f));
  const REAL cx = box.X + box.Width / 2.f;
  const REAL cy = box.Y + box.Height / 2.f;
  const REAL s = (std::min)(box.Width, box.Height);

  auto dial = [&]() {
    g.DrawEllipse(&pen, box.X + s * 0.12f, box.Y + s * 0.12f, s * 0.76f, s * 0.76f);
    g.DrawLine(&pen, cx, cy, cx + s * 0.22f, cy - s * 0.18f);
    g.FillEllipse(&br, cx - s * 0.06f, cy - s * 0.06f, s * 0.12f, s * 0.12f);
  };
  auto bars = [&](int n, float gap) {
    const float bw = s * 0.12f;
    const float total = n * bw + (n - 1) * gap;
    float x0 = cx - total / 2.f;
    for (int i = 0; i < n; ++i) {
      const float h = s * (0.35f + (i % 3) * 0.18f);
      g.FillRectangle(&br, x0 + i * (bw + gap), cy - h / 2.f, bw, h);
    }
  };

  using RI = Win7ChromeShell::RowIcon;
  switch (kind) {
    case RI::Tune:
      dial();
      break;
    case RI::Equalizer:
    case RI::GraphicEq:
      bars(kind == RI::GraphicEq ? 5 : 4, s * 0.08f);
      break;
    case RI::Repeat: {
      g.DrawArc(&pen, box.X + s * 0.18f, box.Y + s * 0.22f, s * 0.64f, s * 0.56f, 40.f, 220.f);
      PointF a[] = {{box.X + s * 0.62f, box.Y + s * 0.18f},
                    {box.X + s * 0.78f, box.Y + s * 0.3f},
                    {box.X + s * 0.58f, box.Y + s * 0.34f}};
      g.FillPolygon(&br, a, 3);
      break;
    }
    case RI::Sunny: {
      g.FillEllipse(&br, cx - s * 0.16f, cy - s * 0.16f, s * 0.32f, s * 0.32f);
      for (int i = 0; i < 8; ++i) {
        const float a = i * 3.14159265f / 4.f;
        g.DrawLine(&pen, cx + std::cos(a) * s * 0.28f, cy + std::sin(a) * s * 0.28f,
                   cx + std::cos(a) * s * 0.42f, cy + std::sin(a) * s * 0.42f);
      }
      break;
    }
    case RI::SkipNext: {
      PointF tri[] = {{box.X + s * 0.22f, box.Y + s * 0.22f},
                      {box.X + s * 0.22f, box.Y + s * 0.78f},
                      {box.X + s * 0.62f, cy}};
      g.FillPolygon(&br, tri, 3);
      g.FillRectangle(&br, box.X + s * 0.68f, box.Y + s * 0.22f, s * 0.1f, s * 0.56f);
      break;
    }
    case RI::Playlist: {
      for (int i = 0; i < 3; ++i) {
        const float y = box.Y + s * (0.22f + i * 0.22f);
        g.DrawLine(&pen, box.X + s * 0.2f, y, box.X + s * 0.78f, y);
      }
      break;
    }
    case RI::Search: {
      g.DrawEllipse(&pen, box.X + s * 0.18f, box.Y + s * 0.18f, s * 0.48f, s * 0.48f);
      g.DrawLine(&pen, box.X + s * 0.58f, box.Y + s * 0.58f, box.X + s * 0.82f, box.Y + s * 0.82f);
      break;
    }
    case RI::Bedtime: {
      GraphicsPath moon;
      moon.AddArc(box.X + s * 0.2f, box.Y + s * 0.18f, s * 0.55f, s * 0.55f, 40.f, 280.f);
      g.DrawPath(&pen, &moon);
      break;
    }
    case RI::Cast: {
      RECT ir = rc;
      DrawChromeIcon(hdc, ir, ChromeIcon::Cast, color);
      break;
    }
    case RI::Pip: {
      RECT ir = rc;
      DrawChromeIcon(hdc, ir, ChromeIcon::Pip, color);
      break;
    }
    case RI::Sparkle: {
      PointF star[] = {{cx, box.Y + s * 0.1f},
                       {cx + s * 0.12f, cy - s * 0.08f},
                       {box.X + s * 0.9f, cy},
                       {cx + s * 0.12f, cy + s * 0.08f},
                       {cx, box.Y + s * 0.9f},
                       {cx - s * 0.12f, cy + s * 0.08f},
                       {box.X + s * 0.1f, cy},
                       {cx - s * 0.12f, cy - s * 0.08f}};
      g.FillPolygon(&br, star, 8);
      break;
    }
    case RI::Refresh: {
      RECT ir = rc;
      DrawChromeIcon(hdc, ir, ChromeIcon::Replay, color);
      break;
    }
    case RI::Favorite: {
      PointF heart[] = {{cx, box.Y + s * 0.72f},
                        {box.X + s * 0.18f, cy},
                        {box.X + s * 0.18f, box.Y + s * 0.32f},
                        {cx - s * 0.12f, box.Y + s * 0.18f},
                        {cx, box.Y + s * 0.32f},
                        {cx + s * 0.12f, box.Y + s * 0.18f},
                        {box.X + s * 0.82f, box.Y + s * 0.32f},
                        {box.X + s * 0.82f, cy}};
      g.FillPolygon(&br, heart, 8);
      break;
    }
    case RI::Layers: {
      PointF a[] = {{cx, box.Y + s * 0.18f},
                    {box.X + s * 0.82f, box.Y + s * 0.38f},
                    {cx, box.Y + s * 0.58f},
                    {box.X + s * 0.18f, box.Y + s * 0.38f}};
      g.DrawPolygon(&pen, a, 4);
      g.DrawLine(&pen, box.X + s * 0.18f, box.Y + s * 0.5f, cx, box.Y + s * 0.7f);
      g.DrawLine(&pen, cx, box.Y + s * 0.7f, box.X + s * 0.82f, box.Y + s * 0.5f);
      break;
    }
    case RI::Info: {
      g.DrawEllipse(&pen, box.X + s * 0.18f, box.Y + s * 0.18f, s * 0.64f, s * 0.64f);
      g.FillEllipse(&br, cx - s * 0.05f, box.Y + s * 0.3f, s * 0.1f, s * 0.1f);
      g.FillRectangle(&br, cx - s * 0.05f, box.Y + s * 0.46f, s * 0.1f, s * 0.28f);
      break;
    }
    case RI::FullscreenExit: {
      RECT ir = rc;
      DrawChromeIcon(hdc, ir, ChromeIcon::CloseFs, color);
      break;
    }
    case RI::Subtitles:
      DrawTextLine(hdc, rc, L"CC", color, 10, true, DT_CENTER | DT_VCENTER | DT_SINGLELINE);
      break;
    case RI::None:
      break;
  }
}

void DrawBadge(HDC hdc, int x, int y, const std::wstring& text) {
  if (text.empty()) return;
  RECT brc{x, y, x + 28, y + 14};
  FillRoundRect(hdc, brc, 3, kPink);
  DrawTextLine(hdc, brc, text, RGB(255, 255, 255), 8, true, DT_CENTER | DT_VCENTER | DT_SINGLELINE);
}

void DrawSeekTrack(HDC hdc, const RECT& track, double progress, bool knob,
                   COLORREF fill = kPink, double buffered = -1) {
  FillRoundRect(hdc, track, 2, RGB(55, 48, 62));
  const int w = track.right - track.left;
  if (buffered > progress && buffered > 0) {
    const int bw = static_cast<int>(w * std::clamp(buffered, 0.0, 1.0));
    if (bw > 0) {
      RECT buf{track.left, track.top, track.left + bw, track.bottom};
      FillRoundRect(hdc, buf, 2, RGB(90, 78, 98));
    }
  }
  const int filled = static_cast<int>(w * std::clamp(progress, 0.0, 1.0));
  if (filled > 0) {
    RECT prog{track.left, track.top, track.left + filled, track.bottom};
    FillRoundRect(hdc, prog, 2, fill);
  }
  if (knob && filled >= 0) {
    const int kx = track.left + filled;
    const int ky = (track.top + track.bottom) / 2;
    HBRUSH white = CreateSolidBrush(RGB(255, 255, 255));
    HGDIOBJ old = SelectObject(hdc, white);
    HPEN pen = CreatePen(PS_SOLID, 1, RGB(255, 255, 255));
    HGDIOBJ old_pen = SelectObject(hdc, pen);
    Ellipse(hdc, kx - 6, ky - 6, kx + 6, ky + 6);
    SelectObject(hdc, old_pen);
    SelectObject(hdc, old);
    DeleteObject(pen);
    DeleteObject(white);
  }
}

std::wstring FmtMmSs(int sec) {
  if (sec < 0) sec = 0;
  wchar_t buf[16];
  swprintf_s(buf, L"%02d:%02d", sec / 60, sec % 60);
  return buf;
}

}  // namespace

Win7ChromeShell::Win7ChromeShell() {

  Gdiplus::GdiplusStartupInput input;
  Gdiplus::GdiplusStartup(&gdiplus_token_, &input, nullptr);
}

Win7ChromeShell::~Win7ChromeShell() {
  DestroyAll();
  SubclassHost(false);
  if (gdiplus_token_) {
    Gdiplus::GdiplusShutdown(gdiplus_token_);
    gdiplus_token_ = 0;
  }
}

void Win7ChromeShell::SetEventSink(EventFn fn) { event_fn_ = std::move(fn); }

void Win7ChromeShell::Attach(HWND host) {
  if (host_hwnd_ == host) return;
  SubclassHost(false);
  host_hwnd_ = host;
  if (host_hwnd_ && enabled_) SubclassHost(true);
}

void Win7ChromeShell::SubclassHost(bool enable) {
  if (!host_hwnd_ && enable) return;
  HWND root = host_hwnd_ ? GetAncestor(host_hwnd_, GA_ROOT) : root_hwnd_;
  if (enable) {
    if (!host_subclassed_ && host_hwnd_) {
      if (SetWindowSubclass(host_hwnd_, HostSubclassProc, kSubclassIdHost,
                            reinterpret_cast<DWORD_PTR>(this))) {
        host_subclassed_ = true;
      }
    }
    // 顶层框移动时子 HWND 不会收到 WM_MOVE；必须挂 root 才能让 POPUP 弹层跟随
    if (root && !root_subclassed_) {
      if (SetWindowSubclass(root, RootSubclassProc, kSubclassIdRoot,
                            reinterpret_cast<DWORD_PTR>(this))) {
        root_subclassed_ = true;
        root_hwnd_ = root;
      }
    }
  } else {
    if (host_subclassed_ && host_hwnd_) {
      RemoveWindowSubclass(host_hwnd_, HostSubclassProc, kSubclassIdHost);
      host_subclassed_ = false;
    }
    if (root_subclassed_ && root_hwnd_) {
      RemoveWindowSubclass(root_hwnd_, RootSubclassProc, kSubclassIdRoot);
      root_subclassed_ = false;
      root_hwnd_ = nullptr;
    }
  }
}

void Win7ChromeShell::SetEnabled(bool enabled) {
  enabled_ = enabled;
  CloseSheet(false);
  if (enabled_) {
    EnsureClasses();
    SubclassHost(true);
    Layout();
  } else {
    DestroyAll();
    SubclassHost(false);
  }
}

HWND Win7ChromeShell::RootHwnd() const {
  return host_hwnd_ ? GetAncestor(host_hwnd_, GA_ROOT) : nullptr;
}

void Win7ChromeShell::EnsureClasses() {
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

  WNDCLASSW gc{};
  gc.lpfnWndProc = GestureWndProc;
  gc.hInstance = GetModuleHandleW(nullptr);
  gc.lpszClassName = kGestureClass;
  gc.hCursor = LoadCursor(nullptr, IDC_ARROW);
  gc.hbrBackground = reinterpret_cast<HBRUSH>(GetStockObject(NULL_BRUSH));
  RegisterClassW(&gc);
  classes_ready_ = true;
}

HWND Win7ChromeShell::CreateChildPanel(const wchar_t* title) {
  HWND parent = HostHwnd();
  if (!parent) return nullptr;
  HWND hwnd = CreateWindowExW(WS_EX_NOACTIVATE, kClass, title,
                              WS_CHILD | WS_CLIPSIBLINGS, 0, 0, 0, 0, parent, nullptr,
                              GetModuleHandleW(nullptr), this);
  if (hwnd) SetWindowLongPtrW(hwnd, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(this));
  return hwnd;
}

HWND Win7ChromeShell::CreateLayeredPopup(const wchar_t* class_name) {
  HWND owner = RootHwnd();
  if (!owner) return nullptr;
  // 归属 owner、不 TOPMOST：随主窗 Z 序；位置由 SyncModalToHost 用屏幕坐标对齐客户区
  HWND hwnd = CreateWindowExW(WS_EX_LAYERED | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE,
                              class_name, L"", WS_POPUP, 0, 0, 0, 0, owner, nullptr,
                              GetModuleHandleW(nullptr), this);
  if (hwnd) {
    SetWindowLongPtrW(hwnd, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(this));
    // Win7 LWA_ALPHA 为整窗恒定透明度；勿依赖 per-pixel ARGB / SourceCopy
    SetLayeredWindowAttributes(hwnd, 0, 235, LWA_ALPHA);
  }
  return hwnd;
}

void Win7ChromeShell::ApplyRoundRegion(HWND hwnd, int w, int h, int radius) {
  if (!hwnd || w <= 0 || h <= 0) return;
  HRGN rgn = CreateRoundRectRgn(0, 0, w + 1, h + 1, radius * 2, radius * 2);
  SetWindowRgn(hwnd, rgn, TRUE);
}

void Win7ChromeShell::DestroyAll() {
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
  if (hold_speed_timer_ && gesture_.hwnd) {
    KillTimer(gesture_.hwnd, hold_speed_timer_);
    hold_speed_timer_ = 0;
  }
  if (episodes_close_timer_ && host_hwnd_) {
    KillTimer(host_hwnd_, episodes_close_timer_);
    episodes_close_timer_ = 0;
  }
  destroy(top_.hwnd);
  destroy(bottom_.hwnd);
  destroy(episodes_.hwnd);
  destroy(live_left_.hwnd);
  destroy(live_right_.hwnd);
  destroy(channel_info_.hwnd);
  destroy(center_play_.hwnd);
  destroy(gesture_.hwnd);
  destroy(danmaku_hwnd_);
  destroy(modal_hwnd_);
}

void Win7ChromeShell::ShowPanel(Panel& p, bool show, int x, int y, int w, int h) {
  if (!p.hwnd) return;
  if (!show || w <= 0 || h <= 0) {
    if (p.shown) ShowWindow(p.hwnd, SW_HIDE);
    p.shown = false;
    return;
  }
  const bool moved = !p.shown || p.x != x || p.y != y || p.w != w || p.h != h;
  if (moved) {
    SetWindowPos(p.hwnd, HWND_TOP, x, y, w, h, SWP_SHOWWINDOW | SWP_NOACTIVATE);
    p.x = x;
    p.y = y;
    p.w = w;
    p.h = h;
    // 几何变才擦背景；进度刷新走 InvalidateChrome(FALSE)。
    InvalidateRect(p.hwnd, nullptr, FALSE);
  } else if (!IsWindowVisible(p.hwnd)) {
    ShowWindow(p.hwnd, SW_SHOWNOACTIVATE);
  }
  p.shown = true;
}

void Win7ChromeShell::Layout() {
  HWND parent = HostHwnd();
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
  if (!gesture_.hwnd) {
    gesture_.hwnd = CreateWindowExW(WS_EX_LAYERED | WS_EX_NOACTIVATE, kGestureClass, L"kotv_gesture",
                                    WS_CHILD | WS_CLIPSIBLINGS, 0, 0, 0, 0, parent, nullptr,
                                    GetModuleHandleW(nullptr), this);
    if (gesture_.hwnd) {
      SetWindowLongPtrW(gesture_.hwnd, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(this));
      // 几乎全透明但可命中（与 Flutter 画面手势层同职责）
      SetLayeredWindowAttributes(gesture_.hwnd, 0, 1, LWA_ALPHA);
    }
  }
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
  const bool live_mode = mode_ == "live";
  if (inline_mode) {
    // 详情非全屏：底栏锚在视频卡片控件区（视图逻辑坐标 × DPI → 子窗客户区）
    int ax = 0, ay = 0, aw = 0, ah = 0;
    const bool ok = bottom_visible_ && ResolveAnchor(&ax, &ay, &aw, &ah);
    ShowPanel(top_, false, 0, 0, 0, 0);
    ShowPanel(episodes_, false, 0, 0, 0, 0);
    ShowPanel(live_left_, false, 0, 0, 0, 0);
    ShowPanel(live_right_, false, 0, 0, 0, 0);
    ShowPanel(channel_info_, false, 0, 0, 0, 0);
    ShowPanel(center_play_, false, 0, 0, 0, 0);
    ShowPanel(bottom_, ok, ax, ay, aw, ah > 0 ? ah : kInlineBottomH);
    // 整栏半透明近似 VodInlineControls 0xCC0A0A12
    if (bottom_.hwnd) {
      const LONG ex = GetWindowLongW(bottom_.hwnd, GWL_EXSTYLE);
      if ((ex & WS_EX_LAYERED) == 0) {
        SetWindowLongW(bottom_.hwnd, GWL_EXSTYLE, ex | WS_EX_LAYERED);
      }
      SetLayeredWindowAttributes(bottom_.hwnd, 0, kInlineBarAlpha, LWA_ALPHA);
    }
  } else if (live_mode) {
    // 直播：无点播顶底栏；左栏顶满；频道信息条仅在左右栏都关时出现（对齐 Flutter）
    ShowPanel(top_, false, 0, 0, 0, 0);
    if (bottom_.hwnd) {
      const LONG ex = GetWindowLongW(bottom_.hwnd, GWL_EXSTYLE);
      if (ex & WS_EX_LAYERED) {
        SetWindowLongW(bottom_.hwnd, GWL_EXSTYLE, ex & ~WS_EX_LAYERED);
      }
    }
    ShowPanel(bottom_, false, 0, 0, 0, 0);
    ShowPanel(episodes_, false, 0, 0, 0, 0);
    ShowPanel(center_play_, false, 0, 0, 0, 0);
    const int left_w =
        kLivePad * 2 + kLiveGroupW + 6 + kLiveChannelW + 6 + kLiveEpgTabW +
        (epg_open_ ? (6 + kLiveEpgW) : 0);
    ShowPanel(live_left_, live_left_visible_, 0, 0, std::min(W, left_w), H);
    ShowPanel(live_right_, live_right_visible_, std::max(0, W - kLiveRightW), 0, kLiveRightW, H);
    const bool show_ch =
        channel_visible_ && !live_left_visible_ && !live_right_visible_;
    ShowPanel(channel_info_, show_ch, 16, H - kChannelH - 16, std::max(0, W - 32), kChannelH);
  } else {
    // 全屏/铺满：半透明顶底栏叠在满屏视频上（对齐 VodFullscreenChrome），勿清 LAYERED。
    auto make_layered = [](HWND h, BYTE alpha) {
      if (!h) return;
      const LONG ex = GetWindowLongW(h, GWL_EXSTYLE);
      if ((ex & WS_EX_LAYERED) == 0) {
        SetWindowLongW(h, GWL_EXSTYLE, ex | WS_EX_LAYERED);
      }
      SetLayeredWindowAttributes(h, 0, alpha, LWA_ALPHA);
    };
    make_layered(top_.hwnd, kFsTopBarAlpha);
    make_layered(bottom_.hwnd, kFsBottomBarAlpha);
    ShowPanel(top_, top_visible_, 0, 0, W, kTopH);
    ShowPanel(bottom_, bottom_visible_, 0, H - kBottomH, W, kBottomH);
    // 选集叠在右侧；视频已铺满，面板盖住画面即可（勿再靠缩 HWND 留边）。
    ShowPanel(episodes_, episodes_visible_, W - kEpW, 0, kEpW, H);
    ShowPanel(live_left_, false, 0, 0, 0, 0);
    ShowPanel(live_right_, false, 0, 0, 0, 0);
    ShowPanel(channel_info_, false, 0, 0, 0, 0);
    ShowPanel(center_play_, center_visible_, (W - kCenterSz) / 2, (H - kCenterSz) / 2, kCenterSz,
              kCenterSz);
  }
  LayoutGesture();
  LayoutDanmaku();
  LayoutModal();
  RaiseChromeZ();
}

void Win7ChromeShell::LayoutGesture() {
  // 点播全屏 / 直播：画面区透明命中层；内嵌用 surface 锚点
  int x = 0, y = 0, w = 0, h = 0;
  bool show = false;
  if (mode_ == "vod_inline") {
    show = ResolveSurface(&x, &y, &w, &h);
  } else if (mode_ == "live" || mode_ == "vod") {
    HWND parent = HostHwnd();
    RECT rc{};
    if (parent) GetClientRect(parent, &rc);
    // 视频铺满客户区时手势层也铺满；栏为叠层，勿再按 top/bottom 内缩命中区。
    x = 0;
    y = 0;
    w = rc.right - rc.left;
    h = rc.bottom - rc.top;
    show = enabled_ && w > 8 && h > 8;
  }
  ShowPanel(gesture_, show && enabled_, x, y, w, h);
  if (gesture_.hwnd && show) {
    // 手势层在视频上、播控下
    SetWindowPos(gesture_.hwnd, HWND_BOTTOM, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
  }
}

void Win7ChromeShell::InvalidateChrome() {
  // FALSE：不擦背景，减轻进度刷新时整栏闪烁。
  auto inv = [](HWND h) {
    if (h) InvalidateRect(h, nullptr, FALSE);
  };
  inv(top_.hwnd);
  inv(bottom_.hwnd);
  inv(episodes_.hwnd);
  inv(live_left_.hwnd);
  inv(live_right_.hwnd);
  inv(channel_info_.hwnd);
  inv(center_play_.hwnd);
}

void Win7ChromeShell::BeginHits(std::vector<HitTarget>* sink) {
  hit_sink_ = sink;
  if (hit_sink_) hit_sink_->clear();
}

void Win7ChromeShell::AddHit(const char* id, const RECT& rc) {
  if (!hit_sink_ || !id || rc.right <= rc.left || rc.bottom <= rc.top) return;
  hit_sink_->push_back(HitTarget{id, rc});
}

const Win7ChromeShell::HitTarget* Win7ChromeShell::HitTest(const std::vector<HitTarget>& hits,
                                                          int x, int y) const {
  for (auto it = hits.rbegin(); it != hits.rend(); ++it) {
    if (x >= it->rc.left && x < it->rc.right && y >= it->rc.top && y < it->rc.bottom) {
      return &(*it);
    }
  }
  return nullptr;
}

std::string Win7ChromeShell::AspectKey() const {
  static const char* k[] = {"default", "fill", "zoom", "16:9", "4:3"};
  const int i = std::clamp(aspect_idx_, 0, 4);
  return k[i];
}

std::wstring Win7ChromeShell::AspectBadge() const {
  static const wchar_t* k[] = {L"适", L"拉", L"Z", L"16", L"4"};
  return k[std::clamp(aspect_idx_, 0, 4)];
}

std::string Win7ChromeShell::DecodeKey() const {
  static const char* k[] = {"auto", "soft", "hard"};
  return k[std::clamp(decode_idx_, 0, 2)];
}

std::wstring Win7ChromeShell::DecodeBadge() const {
  static const wchar_t* k[] = {L"A", L"软", L"硬"};
  return k[std::clamp(decode_idx_, 0, 2)];
}

void Win7ChromeShell::EmitOffsets() {
  Emit({{"type", "offsets"},
        {"openingSec", ChromeValue(static_cast<int64_t>(opening_sec_))},
        {"endingSec", ChromeValue(static_cast<int64_t>(ending_sec_))}});
}

void Win7ChromeShell::OpenSheet(const std::string& kind, const std::wstring& title,
                                std::vector<LineItem> items) {
  sheet_kind_ = kind;
  sheet_title_ = title;
  sheet_subtitle_.clear();
  sheet_items_ = std::move(items);
  sheet_selected_ = 0;
  EnsureClasses();
  LayoutModal();
}

void Win7ChromeShell::OpenChoiceSheet(
    const std::string& kind, const std::wstring& title,
    const std::vector<std::pair<std::string, std::wstring>>& options,
    const std::string& selected_id) {
  std::vector<LineItem> items;
  items.reserve(options.size());
  for (const auto& opt : options) {
    LineItem it;
    it.id = opt.first;
    it.label = opt.second;
    it.chevron = false;
    it.trailing = (!selected_id.empty() && opt.first == selected_id) ? L"✓" : L"";
    items.push_back(std::move(it));
  }
  OpenSheet(kind, title, std::move(items));
}

void Win7ChromeShell::OpenMoreSheet() {
  auto iconFor = [](const std::string& id) -> RowIcon {
    if (id == "videoEq" || id == "danmakuSettings") return RowIcon::Tune;
    if (id == "audioFx") return RowIcon::Equalizer;
    if (id == "repeat") return RowIcon::Repeat;
    if (id == "ambient") return RowIcon::Sunny;
    if (id == "stableVolume") return RowIcon::GraphicEq;
    if (id == "loopSkip") return RowIcon::SkipNext;
    if (id == "danmakuSource") return RowIcon::Playlist;
    if (id == "danmakuSearch") return RowIcon::Search;
    if (id == "sleep") return RowIcon::Bedtime;
    if (id == "cast") return RowIcon::Cast;
    if (id == "mini") return RowIcon::Pip;
    if (id == "parse") return RowIcon::Sparkle;
    if (id == "replay") return RowIcon::Refresh;
    if (id == "keep") return RowIcon::Favorite;
    if (id == "render") return RowIcon::Layers;
    if (id == "playInfo") return RowIcon::Info;
    if (id == "exit" || id == "expandWindow" || id == "expandDisplay") return RowIcon::FullscreenExit;
    if (id == "danmaku") return RowIcon::Subtitles;
    return RowIcon::None;
  };
  // 列表只来自 Dart moreItems（或 LoadDemo 预填）；不在此造假菜单
  std::vector<LineItem> items = more_items_;
  if (!items.empty() && mode_ != "vod_inline") {
    std::vector<LineItem> filtered;
    for (auto& it : items) {
      // 全屏「更多」与 Flutter _showMore 一致：底栏已有的项不重复
      if (it.id == "speed" || it.id == "player" || it.id == "danmaku" || it.id == "episodes") continue;
      if (it.icon == RowIcon::None) it.icon = iconFor(it.id);
      if (!it.toggle) it.chevron = true;
      filtered.push_back(std::move(it));
    }
    items = std::move(filtered);
  } else {
    for (auto& it : items) {
      if (it.icon == RowIcon::None) it.icon = iconFor(it.id);
      if (!it.toggle) it.chevron = true;
    }
  }
  if (items.empty()) return;
  OpenSheet("more", L"更多", std::move(items));
}

void Win7ChromeShell::OpenFullscreenKindSheet() {
  OpenChoiceSheet("fullscreenKind", L"全屏",
                  {{"window", L"铺满当前窗口"}, {"display", L"占满整块屏幕"}});
}

void Win7ChromeShell::OpenDanmakuSheet() {
  std::vector<LineItem> items;
  auto tog = [&](const char* id, const wchar_t* label, bool on) {
    LineItem it;
    it.id = id;
    it.label = label;
    it.toggle = true;
    it.on = on;
    items.push_back(std::move(it));
  };
  auto sl = [&](const char* id, const wchar_t* label, double v, double mn, double mx) {
    LineItem it;
    it.id = id;
    it.label = label;
    it.slider = true;
    it.slider_value = v;
    it.slider_min = mn;
    it.slider_max = mx;
    items.push_back(std::move(it));
  };
  tog("danmaku", L"开启弹幕", danmaku_enabled_);
  tog("danmakuShowScroll", L"滚动弹幕", danmaku_show_scroll_);
  tog("danmakuShowTop", L"顶部弹幕", danmaku_show_top_);
  tog("danmakuShowBottom", L"底部弹幕", danmaku_show_bottom_);
  tog("danmakuShowReverse", L"逆向弹幕", danmaku_show_reverse_);
  tog("danmakuShowPositioned", L"定位弹幕", danmaku_show_positioned_);
  tog("danmakuShowSpecial", L"特殊弹幕", danmaku_show_special_);
  tog("danmakuBold", L"粗体", danmaku_bold_);
  sl("danmakuSize", L"字号", danmaku_font_, 12, 48);
  sl("danmakuOpacity", L"透明度", danmaku_opacity_ * 100.0, 15, 100);
  sl("danmakuRows", L"行数", static_cast<double>(danmaku_rows_), 1, 16);
  sl("danmakuMaxOnScreen", L"同屏上限", static_cast<double>(danmaku_max_on_screen_), 10, 500);
  sl("danmakuScrollArea", L"滚动区域", danmaku_scroll_area_ * 100.0, 10, 100);
  sl("danmakuDurationMs", L"滚动时长(秒)", danmaku_duration_ms_ / 1000.0, 3, 15);
  sl("danmakuFixedDurationMs", L"固定时长(秒)", danmaku_fixed_ms_ / 1000.0, 2, 10);
  OpenSheet("danmaku", L"弹幕设置", std::move(items));
}

void Win7ChromeShell::OpenVideoEqSheet() {
  static const char* kOk[] = {"off", "natural", "vivid", "soft", "cinema",
                              "warm", "cool", "anime", "custom"};
  bool ok = false;
  for (const char* p : kOk) {
    if (eq_preset_ == p) {
      ok = true;
      break;
    }
  }
  if (!ok) eq_preset_ = "off";
  OpenSheet("videoEq", L"画面调色", {});
}

void Win7ChromeShell::OpenAudioFxSheet() {
  static const char* kOk[] = {"off", "natural", "voice", "bass", "cinema", "custom"};
  bool ok = false;
  for (const char* p : kOk) {
    if (eq_preset_ == p) {
      ok = true;
      break;
    }
  }
  if (!ok) eq_preset_ = "off";
  OpenSheet("audioFx", L"音频效果", {});
}

bool Win7ChromeShell::IsEqSheet() const {
  return sheet_kind_ == "videoEq" || sheet_kind_ == "audioFx";
}

void Win7ChromeShell::ResetVideoEqSliders() {
  video_brightness_ = 0;
  video_contrast_ = 0;
  video_saturation_ = 0;
  video_sharpness_ = 0;
  video_temperature_ = 0;
}

bool Win7ChromeShell::OpensNativeChildSheet(const std::string& id) const {
  // 壳自绘；轨/播放器/弹幕源/播放信息等需 Dart 真数据，不在此列
  return id == "videoEq" || id == "audioFx" || id == "danmakuSettings" || id == "sleep" ||
         id == "speed" || id == "render";
}

void Win7ChromeShell::HandleMoreId(const std::string& id) {
  if (id == "videoEq") {
    OpenVideoEqSheet();
  } else if (id == "audioFx") {
    OpenAudioFxSheet();
  } else if (id == "danmakuSettings") {
    OpenDanmakuSheet();
  } else if (id == "sleep") {
    OpenChoiceSheet("sleep", L"休眠定时器",
                    {{"0", L"关闭"},
                     {"15", L"15 分钟"},
                     {"30", L"30 分钟"},
                     {"45", L"45 分钟"},
                     {"60", L"60 分钟"},
                     {"90", L"90 分钟"}});
  } else if (id == "speed") {
    std::vector<std::pair<std::string, std::wstring>> opts;
    static const double kRates[] = {0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0, 5.0};
    char selected[16] = {};
    snprintf(selected, sizeof(selected), "%g", rate_);
    for (double r : kRates) {
      char idbuf[16];
      snprintf(idbuf, sizeof(idbuf), "%g", r);
      wchar_t label[16];
      if (std::fabs(r - std::round(r)) < 0.01)
        swprintf_s(label, L"x%.0f", r);
      else
        swprintf_s(label, L"x%.1f", r);
      opts.emplace_back(idbuf, label);
    }
    OpenChoiceSheet("speed", L"倍速", opts, selected);
  } else if (id == "render") {
    OpenChoiceSheet("render", L"渲染方式",
                    {{"surface", L"Surface（推荐，HDR）"}, {"texture", L"Texture"}}, render_mode_);
  } else if (id == "episodes") {
    episodes_visible_ = true;
    if (episodes_close_timer_ && host_hwnd_) {
      KillTimer(host_hwnd_, episodes_close_timer_);
      episodes_close_timer_ = 0;
    }
    if (host_hwnd_) {
      episodes_close_timer_ = SetTimer(host_hwnd_, kEpisodesCloseTimerId, kEpisodesCloseMs, nullptr);
    }
    Layout();
    Emit({{"type", ChromeValue(std::string("episodes"))}});
  } else if (id == "exit") {
    Emit({{"type", ChromeValue(std::string("exit"))}});
  }
}

bool Win7ChromeShell::DispatchHit(HWND hwnd, int x, int y) {
  const std::vector<HitTarget>* bucket = nullptr;
  if (hwnd == top_.hwnd) bucket = &top_hits_;
  else if (hwnd == bottom_.hwnd) bucket = &bottom_hits_;
  else if (hwnd == center_play_.hwnd) bucket = &center_hits_;
  if (!bucket) return false;
  const HitTarget* hit = HitTest(*bucket, x, y);
  if (!hit) return false;

  const std::string& id = hit->id;
  if (id == "seek") {
    const double p = std::clamp(
        (x - hit->rc.left) / std::max(1.0, static_cast<double>(hit->rc.right - hit->rc.left)), 0.0,
        1.0);
    ApplyLocalAction("seekFraction", p);
    Emit({{"type", ChromeValue(std::string("seekFraction"))},
          {"value", ChromeValue(p)},
          {"commit", ChromeValue(true)}});
    return true;
  }
  if (id == "volume") {
    const double t =
        std::clamp((x - hit->rc.left) / std::max(1.0, static_cast<double>(hit->rc.right - hit->rc.left)),
                   0.0, 1.0) *
        100.0;
    ApplyLocalAction("volume", t);
    Emit({{"type", "slider"},
          {"id", ChromeValue(std::string("volume"))},
          {"value", ChromeValue(volume_)},
          {"commit", ChromeValue(true)}});
    return true;
  }
  if (id == "volumeToggle") {
    ApplyLocalAction("volumeToggle");
    return true;
  }
  if (id == "exit") {
    Emit({{"type", "exit"}});
    return true;
  }
  if (id == "expand") {
    OpenFullscreenKindSheet();
    return true;
  }
  if (id == "more") {
    OpenMoreSheet();
    Emit({{"type", "more"}, {"id", ChromeValue(std::string("open"))}});
    return true;
  }
  if (id == "subtitle" || id == "audio" || id == "video") {
    // 真轨表由 Dart showSheet；壳不造假列表
    Emit({{"type", "track"},
          {"kind", ChromeValue(id)},
          {"id", ChromeValue(std::string("open"))}});
    return true;
  }
  if (id == "player") {
    Emit({{"type", "more"}, {"id", ChromeValue(std::string("player"))}});
    return true;
  }
  if (id == "speed") {
    ApplyLocalAction("speed");
    Emit({{"type", "speed"}, {"value", ChromeValue(rate_)}, {"rate", ChromeValue(rate_)}});
    return true;
  }
  if (id == "aspect") {
    ApplyLocalAction("aspect");
    Emit({{"type", "aspect"},
          {"id", ChromeValue(AspectKey())},
          {"index", ChromeValue(static_cast<int64_t>(aspect_idx_))}});
    return true;
  }
  if (id == "decode") {
    ApplyLocalAction("decode");
    Emit({{"type", "decode"},
          {"id", ChromeValue(DecodeKey())},
          {"index", ChromeValue(static_cast<int64_t>(decode_idx_))}});
    return true;
  }
  if (id == "openingDec" || id == "openingInc" || id == "openingSet" || id == "endingDec" ||
      id == "endingInc" || id == "endingSet" || id == "resetSkip") {
    ApplyLocalAction(id);
    EmitOffsets();
    return true;
  }
  if (id == "direct") {
    ApplyLocalAction("direct");
    Emit({{"type", "direct"}, {"on", ChromeValue(direct_on_)}});
    return true;
  }

  ApplyLocalAction(id);
  Emit({{"type", ChromeValue(id)}});
  return true;
}

void Win7ChromeShell::ApplyLocalAction(const std::string& type, double value) {
  if (type == "toggle" || type == "togglePlay") {
    playing_ = !playing_;
  } else if (type == "stop") {
    playing_ = false;
    progress_ = 0;
    position_sec_ = 0;
    pos_label_ = L"00:00:00";
  } else if (type == "seekFraction") {
    progress_ = std::clamp(value, 0.0, 1.0);
    int total = 19 * 60 + 6;
    if (!dur_label_.empty()) {
      int h = 0, m = 0, s = 0;
      if (swscanf_s(dur_label_.c_str(), L"%d:%d:%d", &h, &m, &s) == 3)
        total = h * 3600 + m * 60 + s;
      else if (swscanf_s(dur_label_.c_str(), L"%d:%d", &m, &s) == 2)
        total = m * 60 + s;
    }
    const int sec = static_cast<int>(std::lround(progress_ * total));
    position_sec_ = sec;
    wchar_t buf[32];
    swprintf_s(buf, L"%02d:%02d:%02d", sec / 3600, (sec % 3600) / 60, sec % 60);
    pos_label_ = buf;
  } else if (type == "prev" || type == "next") {
    // 壳内仅反馈；选集索引交给 Flutter
  } else if (type == "replay") {
    progress_ = 0;
    position_sec_ = 0;
    pos_label_ = L"00:00:00";
    playing_ = true;
  } else if (type == "speed") {
    static const double kRates[] = {0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0, 5.0};
    int idx = 2;
    for (int i = 0; i < 8; ++i) {
      if (std::fabs(rate_ - kRates[i]) < 0.01) {
        idx = i;
        break;
      }
    }
    rate_ = kRates[(idx + 1) % 8];
  } else if (type == "aspect") {
    aspect_idx_ = (aspect_idx_ + 1) % 5;
  } else if (type == "decode") {
    decode_idx_ = (decode_idx_ + 1) % 3;
  } else if (type == "openingDec") {
    opening_sec_ = std::max(0, opening_sec_ - 5);
  } else if (type == "openingInc") {
    opening_sec_ = std::min(3600, opening_sec_ + 5);
  } else if (type == "endingDec") {
    ending_sec_ = std::max(0, ending_sec_ - 5);
  } else if (type == "endingInc") {
    ending_sec_ = std::min(3600, ending_sec_ + 5);
  } else if (type == "openingSet") {
    opening_sec_ = static_cast<int>(std::lround(position_sec_));
  } else if (type == "endingSet") {
    int total = 19 * 60 + 6;
    ending_sec_ = std::max(0, total - static_cast<int>(std::lround(position_sec_)));
  } else if (type == "resetSkip") {
    opening_sec_ = 0;
    ending_sec_ = 0;
  } else if (type == "episodes") {
    episodes_visible_ = !episodes_visible_;
    if (episodes_close_timer_ && host_hwnd_) {
      KillTimer(host_hwnd_, episodes_close_timer_);
      episodes_close_timer_ = 0;
    }
    if (episodes_visible_ && host_hwnd_) {
      episodes_close_timer_ = SetTimer(host_hwnd_, kEpisodesCloseTimerId, kEpisodesCloseMs, nullptr);
    }
    Layout();
    return;
  } else if (type == "volumeToggle") {
    volume_expanded_ = !volume_expanded_;
  } else if (type == "volume") {
    volume_ = std::clamp(value, 1.0, 100.0);
  } else if (type == "direct") {
    direct_on_ = !direct_on_;
  } else if (type == "mini") {
    mini_active_ = !mini_active_;
  } else if (type == "cast" || type == "stop") {
    // stop already handled; cast 仅 Emit
  }
  InvalidateChrome();
}

double Win7ChromeShell::ViewDpiScale() const {
  HWND parent = HostHwnd();
  if (!parent) return 1.0;
  HDC dc = GetDC(parent);
  double s = 1.0;
  if (dc) {
    s = GetDeviceCaps(dc, LOGPIXELSX) / 96.0;
    ReleaseDC(parent, dc);
  }
  return s > 0 ? s : 1.0;
}

bool Win7ChromeShell::ResolveAnchor(int* x, int* y, int* w, int* h) const {
  if (!anchor_valid_ || anchor_screen_w_ < 8 || anchor_screen_h_ < 8) return false;
  // Dart localToGlobal = Flutter 视图逻辑坐标；转物理像素后直接作子窗客户区坐标。
  const double s = ViewDpiScale();
  *x = static_cast<int>(std::lround(anchor_screen_l_ * s));
  *y = static_cast<int>(std::lround(anchor_screen_t_ * s));
  *w = static_cast<int>(std::lround(anchor_screen_w_ * s));
  *h = static_cast<int>(std::lround(anchor_screen_h_ * s));
  return *w >= 8 && *h >= 8;
}

bool Win7ChromeShell::ResolveSurface(int* x, int* y, int* w, int* h) const {
  if (!surface_valid_ || surface_screen_w_ < 8 || surface_screen_h_ < 8) return false;
  const double s = ViewDpiScale();
  *x = static_cast<int>(std::lround(surface_screen_l_ * s));
  *y = static_cast<int>(std::lround(surface_screen_t_ * s));
  *w = static_cast<int>(std::lround(surface_screen_w_ * s));
  *h = static_cast<int>(std::lround(surface_screen_h_ * s));
  return *w >= 8 && *h >= 8;
}

void Win7ChromeShell::RaiseChromeZ() {
  auto raise = [](HWND h) {
    if (h) SetWindowPos(h, HWND_TOP, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
  };
  // 手势层沉底；播控面板置顶
  if (gesture_.hwnd) {
    SetWindowPos(gesture_.hwnd, HWND_BOTTOM, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
  }
  if (top_.hwnd && top_visible_) raise(top_.hwnd);
  if (bottom_.hwnd && bottom_visible_) raise(bottom_.hwnd);
  if (live_left_.hwnd && live_left_visible_) raise(live_left_.hwnd);
  if (live_right_.hwnd && live_right_visible_) raise(live_right_.hwnd);
  if (episodes_.hwnd && episodes_visible_) raise(episodes_.hwnd);
  if (channel_info_.hwnd && channel_visible_) raise(channel_info_.hwnd);
  if (center_play_.hwnd && center_visible_) raise(center_play_.hwnd);
  if (danmaku_hwnd_ && danmaku_enabled_) raise(danmaku_hwnd_);
}

void Win7ChromeShell::LayoutDanmaku() {
  HWND parent = HostHwnd();
  if (!parent || !danmaku_hwnd_) return;
  if (!danmaku_enabled_) {
    ShowWindow(danmaku_hwnd_, SW_HIDE);
    return;
  }
  int x = 0, y = 0, w = 0, h = 0;
  if (mode_ == "vod_inline") {
    // 内嵌：弹幕只盖画面区，勿铺满整窗（否则会糊在详情元数据上）。
    if (!ResolveSurface(&x, &y, &w, &h)) {
      ShowWindow(danmaku_hwnd_, SW_HIDE);
      return;
    }
    int ax = 0, ay = 0, aw = 0, ah = 0;
    if (ResolveAnchor(&ax, &ay, &aw, &ah) && ah > 0 && ay + ah <= y + h) {
      h = std::max(0, ay - y);
    }
  } else {
    RECT rc{};
    GetClientRect(parent, &rc);
    w = rc.right - rc.left;
    h = rc.bottom - rc.top;
  }
  if (w <= 0 || h <= 0) {
    ShowWindow(danmaku_hwnd_, SW_HIDE);
    return;
  }
  SetWindowPos(danmaku_hwnd_, HWND_TOP, x, y, w, h, SWP_SHOWWINDOW | SWP_NOACTIVATE);
  RaiseChromeZ();
}

int Win7ChromeShell::ModalHeaderH(bool /*light*/) const {
  // more：仅手柄+间距；其它：手柄+标题
  if (sheet_kind_ == "more") return 24;
  return 56;
}

int Win7ChromeShell::ModalRowH(bool /*light*/) const { return kListRowH; }

int Win7ChromeShell::EstimateSheetContentH() const {
  const bool light = sheet_kind_ == "danmaku" || sheet_kind_ == "volume";
  const int header = ModalHeaderH(light);
  if (IsEqSheet()) {
    int h = header + 72;  // pill wrap
    if (eq_preset_ == "custom") {
      if (sheet_kind_ == "videoEq")
        h += 5 * 56 + 56;  // 5 sliders + hold/reset
      else
        h += 3 * 56 + 48;  // 3 sliders + hold
    }
    return h + 16;
  }
  const int rows = static_cast<int>(sheet_items_.size());
  return header + rows * ModalRowH(light) + 16;
}

RECT Win7ChromeShell::ModalCardRect(const RECT& full) const {
  const int fw = full.right - full.left;
  const int fh = full.bottom - full.top;
  const int card_w = (std::max)(0, fw - kSheetPad * 2);
  const int max_h = static_cast<int>(fh * 0.72);
  const int content = EstimateSheetContentH();
  const int card_h = (std::min)(max_h, (std::max)(80, content));
  const int x = full.left + kSheetPad;
  const int y = full.bottom - kSheetPad - card_h;
  return RECT{x, y, x + card_w, y + card_h};
}

void Win7ChromeShell::SyncModalToHost(bool invalidate) {
  if (!modal_hwnd_ || sheet_kind_.empty() || !host_hwnd_) return;
  RECT prc{};
  GetClientRect(host_hwnd_, &prc);
  POINT origin{0, 0};
  ClientToScreen(host_hwnd_, &origin);
  const int fw = prc.right - prc.left;
  const int fh = prc.bottom - prc.top;
  if (fw <= 0 || fh <= 0) return;
  SetWindowPos(modal_hwnd_, nullptr, origin.x, origin.y, fw, fh,
               SWP_NOZORDER | SWP_NOACTIVATE | SWP_SHOWWINDOW);
  RECT full{0, 0, fw, fh};
  modal_card_ = ModalCardRect(full);
  if (invalidate) InvalidateRect(modal_hwnd_, nullptr, TRUE);
}

void Win7ChromeShell::LayoutModal() {
  if (sheet_kind_.empty()) {
    if (modal_hwnd_) ShowWindow(modal_hwnd_, SW_HIDE);
    modal_card_ = {};
    modal_hits_.clear();
    return;
  }
  if (!HostHwnd()) return;
  if (!modal_hwnd_) modal_hwnd_ = CreateLayeredPopup(kModalClass);
  if (!modal_hwnd_) return;

  // 整窗恒定 alpha（约 Flutter black38 观感）；卡片用不透明色绘制
  SetLayeredWindowAttributes(modal_hwnd_, 0, 235, LWA_ALPHA);
  SetWindowRgn(modal_hwnd_, nullptr, TRUE);
  SyncModalToHost(true);
  EmitPointerHold(true);
  sheet_open_hold_ = true;
}

void Win7ChromeShell::CloseSheet(bool emit_close) {
  const std::string kind = sheet_kind_;
  sheet_kind_.clear();
  sheet_items_.clear();
  sheet_title_.clear();
  sheet_subtitle_.clear();
  sheet_scroll_ = 0;
  modal_card_ = {};
  modal_hits_.clear();
  drag_id_.clear();
  if (modal_hwnd_) ShowWindow(modal_hwnd_, SW_HIDE);
  if (sheet_open_hold_) {
    sheet_open_hold_ = false;
    EmitPointerHold(false);
  }
  if (emit_close && !kind.empty()) {
    Emit({{"type", ChromeValue(std::string("sheetClose"))},
          {"kind", ChromeValue(kind)}});
  }
}

void Win7ChromeShell::EmitPointerHold(bool on) {
  if (pointer_hold_ == on && !sheet_open_hold_) return;
  pointer_hold_ = on || sheet_open_hold_;
  Emit({{"type", ChromeValue(std::string("pointerHold"))},
        {"on", ChromeValue(pointer_hold_)}});
}

void Win7ChromeShell::Emit(ChromeMap map) {
  if (event_fn_) event_fn_(std::move(map));
}

void Win7ChromeShell::PaintTop(HDC hdc, const RECT& rc) {
  // 对齐 Flutter 全屏顶栏：半透明黑底 + 左边粉条 + 标题/分辨率 + 右侧「退出」文字
  BeginHits(&top_hits_);
  FillRectColor(hdc, rc, RGB(0, 0, 0));  // 再叠一层；子窗本身不透明，用深色近似 0x66
  FillRectColor(hdc, rc, kBarDark);
  RECT accent{rc.left + 12, rc.top + 10, rc.left + 16, rc.bottom - 10};
  FillRectColor(hdc, accent, kPink);

  RECT title_rc{rc.left + 24, rc.top + 8, rc.right - 100, rc.top + 32};
  DrawTextLine(hdc, title_rc, title_.empty() ? L"播放中" : title_, RGB(255, 255, 255), 17, true);
  if (!subtitle_.empty()) {
    RECT sub{rc.left + 24, rc.top + 30, rc.right - 100, rc.bottom - 6};
    DrawTextLine(hdc, sub, subtitle_, RGB(180, 180, 190), 12, false);
  }

  RECT exit_rc{rc.right - 72, rc.top + 10, rc.right - 16, rc.bottom - 10};
  DrawTextLine(hdc, exit_rc, L"退出", RGB(240, 240, 245), 14, true, DT_CENTER | DT_VCENTER | DT_SINGLELINE);
  AddHit("exit", exit_rc);
}

void Win7ChromeShell::PaintBottom(HDC hdc, const RECT& rc) {
  if (mode_ == "vod_inline") {
    PaintBottomInline(hdc, rc);
  } else {
    PaintBottomFullscreen(hdc, rc);
  }
}

void Win7ChromeShell::PaintBottomInline(HDC hdc, const RECT& rc) {
  // 与 VodInlineControls 同结构：动作行 + 时间 + 音量，底下一根进度（主色 #CF4274）
  BeginHits(&bottom_hits_);
  FillRectColor(hdc, rc, RGB(10, 10, 18));
  const int W = static_cast<int>(rc.right - rc.left);
  const bool narrow = W < 480;
  const int icon = narrow ? 32 : 40;
  const int pad = narrow ? 4 : 8;
  const int bar_h = static_cast<int>(rc.bottom - rc.top);
  const int ay = rc.top + (std::max)(2, (bar_h - 18 - icon) / 2);
  int ax = rc.left + pad;
  auto paint = [&](ChromeIcon kind, const char* id) {
    RECT ir{ax, ay, ax + icon, ay + icon};
    DrawChromeIcon(hdc, ir, kind, RGB(235, 235, 240));
    AddHit(id, ir);
    ax += icon + 2;
  };
  paint(playing_ ? ChromeIcon::Pause : ChromeIcon::Play, "toggle");
  paint(ChromeIcon::Stop, "stop");
  if (show_direct_) paint(direct_on_ ? ChromeIcon::DirectOn : ChromeIcon::DirectOff, "direct");
  paint(ChromeIcon::Cast, "cast");
  paint(mini_active_ ? ChromeIcon::CloseFs : ChromeIcon::Pip, "mini");
  paint(ChromeIcon::Expand, "expand");

  std::wstring time = (pos_label_.empty() ? L"0:00" : pos_label_) + L" / " +
                      (dur_label_.empty() ? L"0:00" : dur_label_);
  const int vol_reserve = volume_expanded_ ? 150 : (narrow ? 44 : 50);
  RECT time_rc{ax + pad, ay, rc.right - vol_reserve, ay + icon};
  DrawTextLine(hdc, time_rc, time, RGB(200, 200, 210), narrow ? 11 : 12);

  if (volume_expanded_) {
    RECT vol_rc{rc.right - 150, ay + 2, rc.right - pad, ay + icon - 2};
    FillRoundRect(hdc, vol_rc, 8, RGB(40, 36, 48));
    RECT icon_rc{vol_rc.left, vol_rc.top, vol_rc.left + 32, vol_rc.bottom};
    DrawChromeIcon(hdc, icon_rc, ChromeIcon::Volume, RGB(235, 235, 240));
    AddHit("volumeToggle", icon_rc);
    RECT vtrack{vol_rc.left + 34, vol_rc.top + 12, vol_rc.right - 8, vol_rc.bottom - 12};
    DrawSeekTrack(hdc, vtrack, volume_ / 100.0, false, kPrimary);
    AddHit("volume", vtrack);
  } else {
    RECT vol_rc{rc.right - 44, ay, rc.right - pad, ay + icon};
    DrawChromeIcon(hdc, vol_rc, ChromeIcon::Volume, RGB(235, 235, 240));
    AddHit("volumeToggle", vol_rc);
  }

  RECT track{rc.left + 10, rc.bottom - 14, rc.right - 10, rc.bottom - 10};
  DrawSeekTrack(hdc, track, progress_, true, kPrimary, buffered_);
  AddHit("seek", track);
}

void Win7ChromeShell::PaintBottomFullscreen(HDC hdc, const RECT& rc) {
  // 对齐 Flutter 全屏底栏：右上时钟 → 进度(左右时间) → 横向动作 + 片头片尾 + 更多/选集 + 音量
  BeginHits(&bottom_hits_);
  FillRectColor(hdc, rc, RGB(0, 0, 0));
  FillRectColor(hdc, rc, kBarDark);
  const int W = rc.right - rc.left;

  RECT clock_rc{rc.right - 160, rc.top + 4, rc.right - 16, rc.top + 28};
  DrawTextLine(hdc, clock_rc, clock_.empty() ? L"--:--:--" : clock_, RGB(255, 255, 255), 20, true,
               DT_RIGHT | DT_VCENTER | DT_SINGLELINE);
  if (!ends_at_.empty()) {
    RECT ends{rc.right - 160, rc.top + 26, rc.right - 16, rc.top + 42};
    DrawTextLine(hdc, ends, ends_at_, RGB(180, 180, 190), 11, false,
                 DT_RIGHT | DT_VCENTER | DT_SINGLELINE);
  }

  const int seek_y = rc.top + 46;
  RECT tL{rc.left + 16, seek_y - 2, rc.left + 90, seek_y + 18};
  RECT tR{rc.right - 90, seek_y - 2, rc.right - 16, seek_y + 18};
  DrawTextLine(hdc, tL, pos_label_.empty() ? L"00:00:00" : pos_label_, RGB(200, 200, 210), 12);
  DrawTextLine(hdc, tR, dur_label_.empty() ? L"00:00:00" : dur_label_, RGB(200, 200, 210), 12, false,
               DT_RIGHT | DT_VCENTER | DT_SINGLELINE);
  // 进度条加高命中带
  RECT track{rc.left + 96, seek_y, rc.right - 96, seek_y + 16};
  RECT track_draw{track.left, seek_y + 6, track.right, seek_y + 10};
  DrawSeekTrack(hdc, track_draw, progress_, true);
  AddHit("seek", track);

  const int ay = rc.top + 72;
  const int icon = 34;
  int ax = rc.left + 12;
  auto paint = [&](ChromeIcon kind, const char* id, const std::wstring& badge = {}) {
    RECT ir{ax, ay, ax + icon, ay + icon};
    DrawChromeIcon(hdc, ir, kind, RGB(235, 235, 240));
    if (!badge.empty()) DrawBadge(hdc, ax + icon - 18, ay - 2, badge);
    AddHit(id, ir);
    ax += icon + 4;
  };
  paint(ChromeIcon::Prev, "prev");
  paint(playing_ ? ChromeIcon::Pause : ChromeIcon::Play, "toggle");
  paint(ChromeIcon::Next, "next");
  {
    wchar_t rb[16];
    if (std::fabs(rate_ - std::round(rate_)) < 0.05)
      swprintf_s(rb, L"x%.0f", rate_);
    else
      swprintf_s(rb, L"x%.1f", rate_);
    paint(ChromeIcon::Speed, "speed", rb);
  }
  paint(ChromeIcon::Replay, "replay");
  paint(ChromeIcon::Aspect, "aspect", AspectBadge());
  paint(ChromeIcon::Decode, "decode", DecodeBadge());
  if (show_direct_)
    paint(direct_on_ ? ChromeIcon::DirectOn : ChromeIcon::DirectOff, "direct");
  paint(ChromeIcon::Cc, "subtitle");
  paint(ChromeIcon::Audio, "audio");
  paint(ChromeIcon::Video, "video");
  paint(ChromeIcon::Devices, "player", L"内");

  RECT sep1{ax + 2, ay + 4, ax + 3, ay + icon - 4};
  FillRectColor(hdc, sep1, RGB(80, 80, 90));
  ax += 10;
  auto tiny = [&](const std::wstring& label, int w, const char* id) {
    RECT tr{ax, ay + 4, ax + w, ay + icon - 4};
    FillRoundRect(hdc, tr, 6, RGB(36, 30, 44));
    DrawTextLine(hdc, tr, label, RGB(230, 230, 235), 11, false,
                 DT_CENTER | DT_VCENTER | DT_SINGLELINE);
    AddHit(id, tr);
    ax += w + 4;
  };
  tiny(L"片头", 36, "openingSet");
  tiny(L"-", 22, "openingDec");
  tiny(FmtMmSs(opening_sec_), 48, "openingSet");
  tiny(L"+", 22, "openingInc");
  tiny(L"片尾", 36, "endingSet");
  tiny(L"-", 22, "endingDec");
  tiny(FmtMmSs(ending_sec_), 48, "endingSet");
  tiny(L"+", 22, "endingInc");
  tiny(L"重置", 36, "resetSkip");

  RECT sep2{ax + 2, ay + 4, ax + 3, ay + icon - 4};
  FillRectColor(hdc, sep2, RGB(80, 80, 90));
  ax += 10;
  tiny(L"更多", 40, "more");
  if (!episode_lines_.empty()) tiny(L"选集", 40, "episodes");

  if (volume_expanded_) {
    RECT vol_rc{rc.right - 150, ay, rc.right - 8, ay + icon};
    FillRoundRect(hdc, vol_rc, 8, RGB(40, 36, 48));
    RECT icon_rc{vol_rc.left, vol_rc.top, vol_rc.left + 32, vol_rc.bottom};
    DrawChromeIcon(hdc, icon_rc, ChromeIcon::Volume, RGB(235, 235, 240));
    AddHit("volumeToggle", icon_rc);
    RECT vt{vol_rc.left + 34, vol_rc.top + 12, vol_rc.right - 8, vol_rc.bottom - 12};
    DrawSeekTrack(hdc, vt, volume_ / 100.0, false);
    AddHit("volume", vt);
  } else {
    RECT vol_rc{rc.right - 44, ay, rc.right - 8, ay + icon};
    DrawChromeIcon(hdc, vol_rc, ChromeIcon::Volume, RGB(235, 235, 240));
    AddHit("volumeToggle", vol_rc);
  }

  if (buffering_) {
    RECT b{rc.left + W / 2 - 40, rc.top + 4, rc.left + W / 2 + 40, rc.top + 22};
    DrawTextLine(hdc, b, L"加载中…", RGB(220, 180, 190), 11, false,
                 DT_CENTER | DT_VCENTER | DT_SINGLELINE);
  }
}

void Win7ChromeShell::PaintEpisodes(HDC hdc, const RECT& rc) {
  FillRectColor(hdc, rc, Blend(kPanelDark, RGB(0, 0, 0), 0.15));
  RECT head{rc.left + 12, rc.top + 10, rc.right - 48, rc.top + 36};
  DrawTextLine(hdc, head, L"选集", RGB(255, 255, 255), 15, true);
  RECT close_rc{rc.right - 40, rc.top + 8, rc.right - 8, rc.top + 36};
  DrawTextLine(hdc, close_rc, L"×", RGB(220, 220, 230), 18, true,
               DT_CENTER | DT_VCENTER | DT_SINGLELINE);
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
  (void)close_rc;
}

void Win7ChromeShell::PaintLiveLeft(HDC hdc, const RECT& rc) {
  // 对齐 Flutter 横屏左栏：分组 | 频道 | 竖条「收起/节目单」| EPG
  FillRectColor(hdc, rc, RGB(248, 246, 250));
  const int pad = kLivePad;
  const int gW = kLiveGroupW;
  const int cW = kLiveChannelW;
  const int tabW = kLiveEpgTabW;
  const int gap = 6;
  const int x0 = rc.left + pad;
  const int y0 = rc.top + pad;
  const int y1 = rc.bottom - pad;
  const int pillH = 32;
  const int chH = 40;

  auto drawPill = [&](const RECT& row, bool sel, const std::wstring& text, bool center) {
    FillRoundRect(hdc, row, 8, sel ? Blend(kPink, RGB(255, 240, 242), 0.35) : RGB(236, 232, 238));
    DrawTextLine(hdc, row, text, sel ? RGB(120, 20, 28) : RGB(50, 48, 56), 12, sel,
                 (center ? DT_CENTER : DT_LEFT) | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS);
  };

  // 分组
  for (size_t i = 0; i < groups_.size(); ++i) {
    const int y = y0 + static_cast<int>(i) * (pillH + 4);
    if (y + pillH > y1) break;
    RECT row{x0, y, x0 + gW, y + pillH};
    drawPill(row, static_cast<int>(i) == group_selected_, groups_[i], true);
  }

  const int cx = x0 + gW + gap;
  if (groups_.empty()) {
    for (size_t i = 0; i < channels_.size(); ++i) {
      const int y = y0 + static_cast<int>(i) * (chH + 2);
      if (y + chH > y1) break;
      RECT row{x0, y, rc.right - pad - tabW - gap, y + chH};
      drawPill(row, static_cast<int>(i) == channel_selected_, channels_[i], false);
    }
  } else {
    for (size_t i = 0; i < channels_.size(); ++i) {
      const int y = y0 + static_cast<int>(i) * (chH + 2);
      if (y + chH > y1) break;
      RECT row{cx, y, cx + cW, y + chH};
      drawPill(row, static_cast<int>(i) == channel_selected_, channels_[i], false);
    }
  }

  // 竖条：收起 / 节目单
  const int tabX = groups_.empty() ? (rc.right - pad - tabW) : (cx + cW + gap);
  RECT tab{tabX, y0, tabX + tabW, y1};
  FillRoundRect(hdc, tab, 8, epg_open_ ? Blend(kPink, RGB(255, 240, 242), 0.4) : RGB(236, 232, 238));
  {
    const std::wstring label = epg_open_ ? L"收起" : L"节目单";
    const int n = static_cast<int>(label.size());
    const int lineH = 16;
    const int totalH = n * lineH;
    int ty = static_cast<int>(tab.top) +
             std::max(0, static_cast<int>((tab.bottom - tab.top - totalH) / 2));
    for (int i = 0; i < n; ++i) {
      RECT ch{tab.left, ty, tab.right, ty + lineH};
      DrawTextLine(hdc, ch, label.substr(static_cast<size_t>(i), 1), RGB(40, 36, 48), 11, true,
                   DT_CENTER | DT_VCENTER | DT_SINGLELINE);
      ty += lineH;
    }
  }

  if (!epg_open_) return;

  const int ex = tabX + tabW + gap;
  const int eW = std::max(80, static_cast<int>(rc.right) - pad - ex);
  RECT head{ex, y0, ex + eW, y0 + 20};
  DrawTextLine(hdc, head, L"EPG", RGB(120, 118, 128), 12, true);
  int dayY = y0 + 22;
  int tx = ex;
  for (size_t i = 0; i < epg_days_.size() && i < 8; ++i) {
    RECT day{tx, dayY, tx + 52, dayY + 24};
    if (day.right > ex + eW) break;
    const bool sel = static_cast<int>(i) == epg_day_selected_;
    FillRoundRect(hdc, day, 6, sel ? Blend(kPink, RGB(255, 240, 242), 0.45) : RGB(236, 232, 238));
    DrawTextLine(hdc, day, epg_days_[i], sel ? RGB(120, 20, 28) : RGB(90, 88, 98), 11, sel,
                 DT_CENTER | DT_VCENTER | DT_SINGLELINE);
    tx += 56;
  }
  const int listY = dayY + 28;
  for (size_t i = 0; i < epg_programs_.size(); ++i) {
    const int y = listY + static_cast<int>(i) * 30;
    if (y + 28 > y1) break;
    RECT row{ex, y, ex + eW, y + 28};
    const bool sel = static_cast<int>(i) == epg_program_selected_;
    if (sel) FillRoundRect(hdc, row, 6, Blend(kPink, RGB(255, 240, 242), 0.5));
    DrawTextLine(hdc, row, epg_programs_[i], sel ? RGB(120, 20, 28) : RGB(50, 48, 56), 11, sel,
                 DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS);
  }
}

void Win7ChromeShell::PaintLiveRight(HDC hdc, const RECT& rc) {
  FillRectColor(hdc, rc, RGB(248, 246, 250));
  RECT head{rc.left + 14, rc.top + 12, rc.right - 14, rc.top + 36};
  DrawTextLine(hdc, head, L"直播设置", RGB(30, 28, 36), 15, true);

  const int start = rc.top + 48;
  const int gap = 8;
  const int pill_h = 36;
  for (size_t i = 0; i < live_right_items_.size(); ++i) {
    const int y = start + static_cast<int>(i) * (pill_h + gap);
    if (y + pill_h > rc.bottom - 12) break;
    RECT pill{rc.left + 12, y, rc.right - 12, y + pill_h};
    FillRoundRect(hdc, pill, 18, RGB(236, 232, 238));
    std::wstring label = live_right_items_[i].label;
    if (!live_right_items_[i].trailing.empty()) {
      label += L"  ";
      label += live_right_items_[i].trailing;
    }
    DrawTextLine(hdc, pill, label, RGB(40, 40, 48), 12, true,
                 DT_CENTER | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS);
  }
}

void Win7ChromeShell::PaintChannelInfo(HDC hdc, const RECT& rc) {
  // 先铺满客户区，避免圆角外露出脏底/粉边；再画圆角信息条（对齐 Flutter 底栏）
  FillRectColor(hdc, rc, RGB(18, 10, 28));
  RECT bar = rc;
  FillRoundRect(hdc, bar, 10, RGB(248, 246, 250));
  RECT no{rc.left + 16, rc.top + 8, rc.left + 64, rc.bottom - 8};
  DrawTextLine(hdc, no, channel_no_.empty() ? L"-" : channel_no_, RGB(120, 118, 128), 20, true,
               DT_LEFT | DT_VCENTER | DT_SINGLELINE);
  // logo 占位圆
  {
    RECT logo{rc.left + 68, rc.top + 12, rc.left + 100, rc.bottom - 12};
    FillRoundRect(hdc, logo, 16, RGB(240, 120, 60));
  }
  RECT name{rc.left + 110, rc.top + 8, rc.right - 16, rc.top + 30};
  DrawTextLine(hdc, name, channel_name_, RGB(30, 30, 36), 16, true);
  RECT prog{rc.left + 110, rc.top + 30, rc.right - 16, rc.bottom - 8};
  const std::wstring prog_text =
      channel_ticker_.empty()
          ? channel_prog_
          : (channel_prog_.empty() ? channel_ticker_ : channel_prog_ + L"  ·  " + channel_ticker_);
  DrawTextLine(hdc, prog, prog_text, RGB(120, 118, 128), 12, false);
}

void Win7ChromeShell::PaintCenter(HDC hdc, const RECT& rc) {
  BeginHits(&center_hits_);
  FillRoundRect(hdc, rc, 36, Blend(kPanelDark, RGB(0, 0, 0), 0.35), RGB(90, 80, 100), 1);
  DrawChromeIcon(hdc, rc, playing_ ? ChromeIcon::Pause : ChromeIcon::Play, RGB(255, 255, 255));
  AddHit("togglePlay", rc);
}

void Win7ChromeShell::PaintModal(HDC hdc, const RECT& rc) {
  BeginHits(&modal_hits_);
  // Win7：LWA_ALPHA 整窗半透明 + 不透明 GDI 填充（per-pixel SourceCopy/ARGB 在 BeginPaint 下无效）
  FillRectColor(hdc, rc, RGB(0, 0, 0));
  RECT card = modal_card_;
  if (card.right <= card.left) card = ModalCardRect(rc);

  const bool light = sheet_kind_ == "danmaku" || sheet_kind_ == "volume";
  FillRoundRect(hdc, card, kSheetRadius, light ? kSheetLight : kSheetDark);

  // 顶手柄 40×4
  {
    const int hx = (card.left + card.right) / 2 - 20;
    const int hy = card.top + 10;
    RECT handle{hx, hy, hx + 40, hy + 4};
    FillRoundRect(hdc, handle, 2, light ? RGB(180, 180, 188) : RGB(90, 90, 98));
  }

  if (IsEqSheet()) {
    PaintEqSheet(hdc, card);
  } else {
    PaintListSheet(hdc, card, light);
  }
}

void Win7ChromeShell::PaintListSheet(HDC hdc, const RECT& card, bool light) {
  const COLORREF fg = light ? RGB(40, 40, 48) : RGB(240, 240, 245);
  const COLORREF muted = light ? RGB(100, 100, 110) : RGB(170, 170, 180);
  const int header = ModalHeaderH(light);
  if (sheet_kind_ != "more" && !sheet_title_.empty()) {
    RECT title{card.left + 16, card.top + 22, card.right - 16, card.top + header};
    DrawTextLine(hdc, title, sheet_title_, fg, 17, true);
  }

  const int row_h = ModalRowH(light);
  const int list_top = card.top + header;
  const int list_bot = card.bottom - 12;
  const int visible = (std::max)(1, (list_bot - list_top) / row_h);
  const int max_scroll =
      (std::max)(0, static_cast<int>(sheet_items_.size()) - visible);
  sheet_scroll_ = std::clamp(sheet_scroll_, 0, max_scroll);

  for (int vis = 0; vis < visible; ++vis) {
    const int i = vis + sheet_scroll_;
    if (i < 0 || i >= static_cast<int>(sheet_items_.size())) break;
    const auto& it = sheet_items_[i];
    const int y = list_top + vis * row_h;
    RECT row{card.left + 8, y, card.right - 8, y + row_h};
    if (i == sheet_selected_) {
      FillRoundRect(hdc, row, 8, light ? RGB(236, 232, 238) : RGB(55, 50, 60));
    }
    AddHit(it.id.c_str(), row);

    int text_l = row.left + 16;
    if (it.icon != RowIcon::None) {
      RECT ir{row.left + 16, y + (row_h - kRowIconSz) / 2, row.left + 16 + kRowIconSz,
              y + (row_h + kRowIconSz) / 2};
      DrawRowIcon(hdc, ir, it.icon, fg);
      text_l = ir.right + 16;
    }

    RECT label_rc{text_l, row.top, row.right - 100, row.bottom};
    DrawTextLine(hdc, label_rc, it.label, fg, 16, false,
                 DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS);
    RECT trail{row.right - 96, row.top, row.right - 28, row.bottom};
    if (it.toggle) {
      // Switch：开轨 #5C5C66
      RECT sw{row.right - 58, y + 14, row.right - 14, y + 38};
      FillRoundRect(hdc, sw, 12, it.on ? RGB(0x5C, 0x5C, 0x66) : RGB(0x3A, 0x3A, 0x42));
      const int knob_x = it.on ? sw.right - 22 : sw.left + 2;
      HBRUSH white = CreateSolidBrush(it.on ? RGB(255, 255, 255) : RGB(0xB0, 0xB0, 0xB8));
      HGDIOBJ old = SelectObject(hdc, white);
      Ellipse(hdc, knob_x, sw.top + 2, knob_x + 20, sw.bottom - 2);
      SelectObject(hdc, old);
      DeleteObject(white);
    } else if (it.slider) {
      const double span = (std::max)(1e-6, it.slider_max - it.slider_min);
      const double t = std::clamp((it.slider_value - it.slider_min) / span, 0.0, 1.0);
      DrawTextLine(hdc, trail,
                   it.trailing.empty()
                       ? Utf8ToWide(std::to_string(static_cast<int>(std::lround(it.slider_value))))
                       : it.trailing,
                   muted, 12, false, DT_RIGHT | DT_TOP | DT_SINGLELINE);
      RECT track{row.left + 16, y + row_h - 18, row.right - 16, y + row_h - 12};
      FillRoundRect(hdc, track, 2, light ? RGB(210, 210, 218) : RGB(70, 65, 78));
      const int filled = static_cast<int>((track.right - track.left) * t);
      RECT prog{track.left, track.top, track.left + filled, track.bottom};
      FillRoundRect(hdc, prog, 2, kPink);
      AddHit(("slider:" + it.id).c_str(), track);
    } else {
      if (!it.trailing.empty()) {
        DrawTextLine(hdc, trail, it.trailing, muted, 15, false, DT_RIGHT | DT_VCENTER | DT_SINGLELINE);
      }
      // link 行永远 chevron（对齐 Flutter linkRow）
      RECT chev{row.right - 28, row.top, row.right - 8, row.bottom};
      DrawTextLine(hdc, chev, L"›", RGB(140, 140, 150), 18, false,
                   DT_CENTER | DT_VCENTER | DT_SINGLELINE);
    }
  }
}

void Win7ChromeShell::PaintEqSheet(HDC hdc, const RECT& card) {
  BeginHits(&modal_hits_);
  const COLORREF fg = RGB(240, 240, 245);
  const COLORREF muted = RGB(170, 170, 180);
  const int header = ModalHeaderH(false);
  RECT title{card.left + 16, card.top + 22, card.right - 16, card.top + header};
  DrawTextLine(hdc, title, sheet_title_, fg, 17, true);

  struct Pill {
    const char* id;
    const wchar_t* label;
  };
  std::vector<Pill> pills;
  if (sheet_kind_ == "videoEq") {
    pills = {{"off", L"关闭"},   {"natural", L"自然"}, {"vivid", L"鲜艳"},
             {"soft", L"柔和"},  {"cinema", L"影院"},  {"warm", L"暖色"},
             {"cool", L"冷色"},  {"anime", L"动漫"},   {"custom", L"自定义"}};
  } else {
    pills = {{"off", L"关闭"},     {"natural", L"自然"}, {"voice", L"人声"},
             {"bass", L"低音"},    {"cinema", L"影院"},  {"custom", L"自定义"}};
  }

  int x = card.left + 12;
  int y = card.top + header;
  const int pill_h = 32;
  const int max_r = card.right - 12;
  for (const auto& p : pills) {
    const bool on = (eq_preset_ == p.id) || (p.id == std::string("off") &&
                                             (eq_preset_.empty() || eq_preset_ == "off"));
    SIZE sz{};
    GetTextExtentPoint32W(hdc, p.label, static_cast<int>(wcslen(p.label)), &sz);
    const int pw = sz.cx + (on ? 36 : 24);
    if (x + pw > max_r) {
      x = card.left + 12;
      y += pill_h + 6;
    }
    RECT pr{x, y, x + pw, y + pill_h};
    FillRoundRect(hdc, pr, 16, on ? RGB(245, 245, 248) : RGB(55, 55, 62));
    RECT tr{pr.left + 8, pr.top, pr.right - 8, pr.bottom};
    DrawTextLine(hdc, tr, on ? (std::wstring(L"✓ ") + p.label) : p.label,
                 on ? RGB(30, 30, 36) : fg, 13, false, DT_CENTER | DT_VCENTER | DT_SINGLELINE);
    AddHit((std::string("pill:") + p.id).c_str(), pr);
    x += pw + 8;
  }
  y += pill_h + 10;

  if (eq_preset_ != "custom") return;

  auto paint_slider = [&](const char* id, const wchar_t* label, double* val, double mn, double mx) {
    RECT lab{card.left + 16, y, card.right - 16, y + 22};
    DrawTextLine(hdc, lab, label, muted, 13);
    y += 24;
    RECT track{card.left + 16, y, card.right - 16, y + 8};
    FillRoundRect(hdc, track, 3, RGB(70, 65, 78));
    const double span = (std::max)(1e-6, mx - mn);
    const double t = std::clamp((*val - mn) / span, 0.0, 1.0);
    const int filled = static_cast<int>((track.right - track.left) * t);
    RECT prog{track.left, track.top, track.left + filled, track.bottom};
    FillRoundRect(hdc, prog, 3, kPink);
    const int kx = track.left + filled;
    HBRUSH white = CreateSolidBrush(RGB(255, 255, 255));
    HGDIOBJ old = SelectObject(hdc, white);
    Ellipse(hdc, kx - 7, track.top - 4, kx + 7, track.bottom + 4);
    SelectObject(hdc, old);
    DeleteObject(white);
    RECT hit = track;
    InflateRect(&hit, 0, 10);
    AddHit((std::string("slider:") + id).c_str(), hit);
    y += 28;
  };

  if (sheet_kind_ == "videoEq") {
    paint_slider("videoBrightness", L"亮度", &video_brightness_, -100, 100);
    paint_slider("videoContrast", L"对比度", &video_contrast_, -100, 100);
    paint_slider("videoSaturation", L"饱和度", &video_saturation_, -100, 100);
    paint_slider("videoSharpness", L"锐度", &video_sharpness_, 0, 100);
    paint_slider("videoTemperature", L"色温", &video_temperature_, -100, 100);
    const int btn_w = (card.right - card.left - 40) / 2;
    RECT hold{card.left + 12, y, card.left + 12 + btn_w, y + 40};
    RECT reset{hold.right + 8, y, hold.right + 8 + btn_w, y + 40};
    FillRoundRect(hdc, hold, 8, RGB(55, 55, 62), RGB(160, 160, 168), 1);
    DrawTextLine(hdc, hold, L"按住看原画", muted, 13, false, DT_CENTER | DT_VCENTER | DT_SINGLELINE);
    FillRoundRect(hdc, reset, 8, RGB(55, 55, 62), RGB(160, 160, 168), 1);
    DrawTextLine(hdc, reset, L"复位", muted, 13, false, DT_CENTER | DT_VCENTER | DT_SINGLELINE);
    AddHit("holdPreview", hold);
    AddHit("resetEq", reset);
  } else {
    paint_slider("audioDialogue", L"对白", &audio_dialogue_, 0, 100);
    paint_slider("audioBalance", L"平衡", &audio_balance_, -100, 100);
    paint_slider("audioOffsetMs", L"音画", &audio_offset_ms_, -5000, 5000);
    RECT hold{card.left + 12, y, card.right - 12, y + 40};
    FillRoundRect(hdc, hold, 8, RGB(55, 55, 62), RGB(160, 160, 168), 1);
    DrawTextLine(hdc, hold, L"按住试听原音", muted, 13, false, DT_CENTER | DT_VCENTER | DT_SINGLELINE);
    AddHit("holdPreview", hold);
  }
}

bool Win7ChromeShell::HandleEqClick(int x, int y, bool down, bool up) {
  if (!IsEqSheet()) return false;
  const HitTarget* hit = HitTest(modal_hits_, x, y);
  // 拖滑条时即使指针离开命中框，仍按 drag_id_ 更新
  if (!hit && !drag_id_.empty() && drag_id_.rfind("slider:", 0) == 0) {
    for (const auto& h : modal_hits_) {
      if (h.id == drag_id_) {
        hit = &h;
        break;
      }
    }
  }
  if (!hit) {
    if (up) drag_id_.clear();
    return false;
  }
  const std::string& id = hit->id;
  if (id.rfind("pill:", 0) == 0 && up) {
    eq_preset_ = id.substr(5);
    Emit({{"type", "sheet"},
          {"id", ChromeValue(eq_preset_)},
          {"kind", ChromeValue(sheet_kind_)}});
    LayoutModal();
    return true;
  }
  if (id.rfind("slider:", 0) == 0) {
    const std::string sid = id.substr(7);
    const double t = std::clamp(
        (x - hit->rc.left) / (std::max)(1.0, static_cast<double>(hit->rc.right - hit->rc.left)), 0.0,
        1.0);
    auto assign = [&](double mn, double mx, double* dst) {
      *dst = mn + t * (mx - mn);
      if (down) drag_id_ = id;
      Emit({{"type", "slider"},
            {"id", ChromeValue(sid)},
            {"value", ChromeValue(*dst)},
            {"commit", ChromeValue(up)},
            {"sheet", ChromeValue(sheet_kind_)}});
    };
    if (sid == "videoBrightness")
      assign(-100, 100, &video_brightness_);
    else if (sid == "videoContrast")
      assign(-100, 100, &video_contrast_);
    else if (sid == "videoSaturation")
      assign(-100, 100, &video_saturation_);
    else if (sid == "videoSharpness")
      assign(0, 100, &video_sharpness_);
    else if (sid == "videoTemperature")
      assign(-100, 100, &video_temperature_);
    else if (sid == "audioDialogue")
      assign(0, 100, &audio_dialogue_);
    else if (sid == "audioBalance")
      assign(-100, 100, &audio_balance_);
    else if (sid == "audioOffsetMs")
      assign(-5000, 5000, &audio_offset_ms_);
    if (up) drag_id_.clear();
    if (modal_hwnd_) InvalidateRect(modal_hwnd_, nullptr, TRUE);
    return true;
  }
  if (id == "holdPreview") {
    Emit({{"type", ChromeValue(std::string("fxPreview"))},
          {"kind", ChromeValue(sheet_kind_)},
          {"on", ChromeValue(down && !up)}});
    return true;
  }
  if (id == "resetEq" && up) {
    ResetVideoEqSliders();
    Emit({{"type", "sheet"},
          {"id", ChromeValue(std::string("reset"))},
          {"kind", ChromeValue(sheet_kind_)}});
    if (modal_hwnd_) InvalidateRect(modal_hwnd_, nullptr, TRUE);
    return true;
  }
  return false;
}

void Win7ChromeShell::PaintPanel(HWND hwnd, HDC hdc, const RECT& rc) {
  if (hwnd == top_.hwnd) PaintTop(hdc, rc);
  else if (hwnd == bottom_.hwnd) PaintBottom(hdc, rc);
  else if (hwnd == episodes_.hwnd) PaintEpisodes(hdc, rc);
  else if (hwnd == live_left_.hwnd) PaintLiveLeft(hdc, rc);
  else if (hwnd == live_right_.hwnd) PaintLiveRight(hdc, rc);
  else if (hwnd == channel_info_.hwnd) PaintChannelInfo(hdc, rc);
  else if (hwnd == center_play_.hwnd) PaintCenter(hdc, rc);
}

void Win7ChromeShell::PaintDanmaku(HWND hwnd) {
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

LRESULT CALLBACK Win7ChromeShell::WndProc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam) {
  if (msg == WM_NCCREATE) {
    auto* cs = reinterpret_cast<CREATESTRUCTW*>(lParam);
    SetWindowLongPtrW(hwnd, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(cs->lpCreateParams));
  }
  auto* self = reinterpret_cast<Win7ChromeShell*>(GetWindowLongPtrW(hwnd, GWLP_USERDATA));
  if (self) return self->OnMessage(hwnd, msg, wParam, lParam);
  return DefWindowProcW(hwnd, msg, wParam, lParam);
}

LRESULT CALLBACK Win7ChromeShell::DanmakuWndProc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam) {
  if (msg == WM_NCCREATE) {
    auto* cs = reinterpret_cast<CREATESTRUCTW*>(lParam);
    SetWindowLongPtrW(hwnd, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(cs->lpCreateParams));
  }
  auto* self = reinterpret_cast<Win7ChromeShell*>(GetWindowLongPtrW(hwnd, GWLP_USERDATA));
  if (self) return self->OnDanmakuMessage(hwnd, msg, wParam, lParam);
  return DefWindowProcW(hwnd, msg, wParam, lParam);
}

LRESULT CALLBACK Win7ChromeShell::ModalWndProc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam) {
  if (msg == WM_NCCREATE) {
    auto* cs = reinterpret_cast<CREATESTRUCTW*>(lParam);
    SetWindowLongPtrW(hwnd, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(cs->lpCreateParams));
  }
  auto* self = reinterpret_cast<Win7ChromeShell*>(GetWindowLongPtrW(hwnd, GWLP_USERDATA));
  if (self) return self->OnModalMessage(hwnd, msg, wParam, lParam);
  return DefWindowProcW(hwnd, msg, wParam, lParam);
}

LRESULT Win7ChromeShell::OnDanmakuMessage(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam) {
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

LRESULT Win7ChromeShell::OnModalMessage(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam) {
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
    case WM_MOUSEWHEEL: {
      const int delta = GET_WHEEL_DELTA_WPARAM(wParam);
      if (delta < 0) sheet_scroll_ += 1;
      else if (delta > 0) sheet_scroll_ = (std::max)(0, sheet_scroll_ - 1);
      InvalidateRect(hwnd, nullptr, TRUE);
      return 0;
    }
    case WM_MOUSEMOVE: {
      if (GetCapture() == hwnd && !drag_id_.empty() && drag_id_.rfind("slider:", 0) == 0) {
        HandleEqClick(GET_X_LPARAM(lParam), GET_Y_LPARAM(lParam), false, false);
        // list-sheet slider drag
        if (!IsEqSheet()) {
          const int x = GET_X_LPARAM(lParam);
          const HitTarget* hit = HitTest(modal_hits_, x, GET_Y_LPARAM(lParam));
          if (hit && hit->id.rfind("slider:", 0) == 0) {
            // handled below via same path as click
          }
          for (auto& it : sheet_items_) {
            if (("slider:" + it.id) != drag_id_) continue;
            const HitTarget* th = nullptr;
            for (const auto& h : modal_hits_) {
              if (h.id == drag_id_) {
                th = &h;
                break;
              }
            }
            if (!th) break;
            const double t = std::clamp(
                (x - th->rc.left) /
                    (std::max)(1.0, static_cast<double>(th->rc.right - th->rc.left)),
                0.0, 1.0);
            it.slider_value = it.slider_min + t * (it.slider_max - it.slider_min);
            Emit({{"type", "slider"},
                  {"id", ChromeValue(it.id)},
                  {"value", ChromeValue(it.slider_value)},
                  {"commit", ChromeValue(false)},
                  {"sheet", ChromeValue(sheet_kind_)}});
            InvalidateRect(hwnd, nullptr, TRUE);
            break;
          }
        }
        return 0;
      }
      return DefWindowProcW(hwnd, msg, wParam, lParam);
    }
    case WM_LBUTTONDOWN:
    case WM_LBUTTONUP: {
      const int x = GET_X_LPARAM(lParam);
      const int y = GET_Y_LPARAM(lParam);
      RECT rc{};
      GetClientRect(hwnd, &rc);
      RECT card = modal_card_;
      if (card.right <= card.left) card = ModalCardRect(rc);
      // 点卡片外：关闭
      if (msg == WM_LBUTTONUP &&
          (x < card.left || x > card.right || y < card.top || y > card.bottom)) {
        CloseSheet(true);
        return 0;
      }
      if (IsEqSheet()) {
        if (msg == WM_LBUTTONDOWN) SetCapture(hwnd);
        if (msg == WM_LBUTTONUP && GetCapture() == hwnd) ReleaseCapture();
        if (HandleEqClick(x, y, msg == WM_LBUTTONDOWN, msg == WM_LBUTTONUP)) return 0;
        return 0;
      }
      const HitTarget* hot = HitTest(modal_hits_, x, y);
      if (!hot) return 0;
      // resolve item by id
      LineItem* it = nullptr;
      int idx = -1;
      for (int i = 0; i < static_cast<int>(sheet_items_.size()); ++i) {
        if (sheet_items_[i].id == hot->id || hot->id == ("slider:" + sheet_items_[i].id)) {
          it = &sheet_items_[i];
          idx = i;
          break;
        }
      }
      if (!it) return 0;
      sheet_selected_ = idx;
      if (it->hold_preview) {
        Emit({{"type", ChromeValue(std::string("fxPreview"))},
              {"kind", ChromeValue(sheet_kind_)},
              {"on", ChromeValue(msg == WM_LBUTTONDOWN)}});
        return 0;
      }
      if (it->slider) {
        if (msg == WM_LBUTTONDOWN) {
          SetCapture(hwnd);
          drag_id_ = "slider:" + it->id;
        }
        const HitTarget* th = hot;
        for (const auto& h : modal_hits_) {
          if (h.id == "slider:" + it->id) {
            th = &h;
            break;
          }
        }
        const double t = std::clamp(
            (x - th->rc.left) / (std::max)(1.0, static_cast<double>(th->rc.right - th->rc.left)),
            0.0, 1.0);
        it->slider_value = it->slider_min + t * (it->slider_max - it->slider_min);
        if (it->id == "danmakuSize")
          danmaku_font_ = it->slider_value;
        else if (it->id == "danmakuOpacity")
          danmaku_opacity_ = it->slider_value / 100.0;
        else if (it->id == "danmakuRows")
          danmaku_rows_ = static_cast<int>(std::lround(it->slider_value));
        else if (it->id == "danmakuMaxOnScreen")
          danmaku_max_on_screen_ = static_cast<int>(std::lround(it->slider_value));
        else if (it->id == "danmakuScrollArea")
          danmaku_scroll_area_ = it->slider_value / 100.0;
        else if (it->id == "danmakuDurationMs")
          danmaku_duration_ms_ = static_cast<int>(std::lround(it->slider_value * 1000.0));
        else if (it->id == "danmakuFixedDurationMs")
          danmaku_fixed_ms_ = static_cast<int>(std::lround(it->slider_value * 1000.0));
        Emit({{"type", "slider"},
              {"id", ChromeValue(it->id)},
              {"value", ChromeValue(it->slider_value)},
              {"commit", ChromeValue(msg == WM_LBUTTONUP)},
              {"sheet", ChromeValue(sheet_kind_)}});
        if (msg == WM_LBUTTONUP) {
          if (GetCapture() == hwnd) ReleaseCapture();
          drag_id_.clear();
        }
        InvalidateRect(hwnd, nullptr, TRUE);
        return 0;
      }
      if (msg != WM_LBUTTONUP) return 0;
      if (it->toggle) {
        it->on = !it->on;
        if (it->id == "danmaku") {
          danmaku_enabled_ = it->on;
          LayoutDanmaku();
        } else if (it->id == "danmakuShowScroll")
          danmaku_show_scroll_ = it->on;
        else if (it->id == "danmakuShowTop")
          danmaku_show_top_ = it->on;
        else if (it->id == "danmakuShowBottom")
          danmaku_show_bottom_ = it->on;
        else if (it->id == "danmakuShowReverse")
          danmaku_show_reverse_ = it->on;
        else if (it->id == "danmakuShowPositioned")
          danmaku_show_positioned_ = it->on;
        else if (it->id == "danmakuShowSpecial")
          danmaku_show_special_ = it->on;
        else if (it->id == "danmakuBold")
          danmaku_bold_ = it->on;
        else if (it->id == "repeat")
          repeat_one_ = it->on;
        else if (it->id == "ambient")
          ambient_on_ = it->on;
        else if (it->id == "stableVolume")
          stable_volume_ = it->on;
        else if (it->id == "loopSkip")
          loop_skip_ = it->on;
        Emit({{"type", "toggleItem"},
              {"id", ChromeValue(it->id)},
              {"on", ChromeValue(it->on)},
              {"sheet", ChromeValue(sheet_kind_)}});
        InvalidateRect(hwnd, nullptr, TRUE);
        InvalidateChrome();
        return 0;
      }
      if (sheet_kind_ == "player") {
        Emit({{"type", "pickPlayer"}, {"id", ChromeValue(it->id)}});
        CloseSheet(false);
        return 0;
      }
      if (sheet_kind_ == "more") {
        CloseSheet(false);
        if (OpensNativeChildSheet(it->id)) {
          HandleMoreId(it->id);
          Emit({{"type", ChromeValue(std::string("more"))},
                {"id", ChromeValue(it->id)},
                {"nativeSheet", ChromeValue(true)}});
        } else {
          Emit({{"type", ChromeValue(std::string("more"))}, {"id", ChromeValue(it->id)}});
          // episodes / exit 等壳侧副作用；player/playInfo/danmakuSource 仅交给 Dart
          HandleMoreId(it->id);
        }
        return 0;
      }
      if (sheet_kind_ == "speed") {
        rate_ = std::strtod(it->id.c_str(), nullptr);
        if (rate_ <= 0) rate_ = 1.0;
        Emit({{"type", "sheet"},
              {"id", ChromeValue(it->id)},
              {"kind", ChromeValue(std::string("speed"))}});
        CloseSheet();
        InvalidateChrome();
        return 0;
      }
      if (sheet_kind_ == "decode") {
        if (it->id == "auto")
          decode_idx_ = 0;
        else if (it->id == "soft")
          decode_idx_ = 1;
        else
          decode_idx_ = 2;
        Emit({{"type", "decode"}, {"id", ChromeValue(it->id)}});
        CloseSheet();
        InvalidateChrome();
        return 0;
      }
      if (sheet_kind_ == "fullscreenKind") {
        Emit({{"type", "sheet"},
              {"id", ChromeValue(it->id)},
              {"kind", ChromeValue(std::string("fullscreenKind"))}});
        CloseSheet();
        return 0;
      }
      if (sheet_kind_ == "subtitle" || sheet_kind_ == "audio" || sheet_kind_ == "video") {
        Emit({{"type", "track"},
              {"kind", ChromeValue(sheet_kind_)},
              {"id", ChromeValue(it->id)}});
        CloseSheet();
        return 0;
      }
      if (sheet_kind_ == "render") {
        render_mode_ = it->id;
        Emit({{"type", "sheet"},
              {"id", ChromeValue(it->id)},
              {"kind", ChromeValue(std::string("render"))}});
        CloseSheet();
        return 0;
      }
      if (sheet_kind_ == "danmakuSource") {
        danmaku_source_idx_ = std::atoi(it->id.c_str());
        Emit({{"type", "sheet"},
              {"id", ChromeValue(it->id)},
              {"kind", ChromeValue(std::string("danmakuSource"))}});
        CloseSheet();
        return 0;
      }
      Emit({{"type", "sheet"},
            {"id", ChromeValue(it->id)},
            {"kind", ChromeValue(sheet_kind_)}});
      CloseSheet();
      return 0;
    }
    case WM_ERASEBKGND:
      return 1;
    default:
      return DefWindowProcW(hwnd, msg, wParam, lParam);
  }
}

LRESULT Win7ChromeShell::OnMessage(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam) {
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
    case WM_MOUSEMOVE: {
      if (GetCapture() == hwnd && (drag_id_ == "seek" || drag_id_ == "volume") &&
          hwnd == bottom_.hwnd) {
        const int x = GET_X_LPARAM(lParam);
        for (const auto& h : bottom_hits_) {
          if (h.id != drag_id_) continue;
          const double t = std::clamp(
              (x - h.rc.left) / std::max(1.0, static_cast<double>(h.rc.right - h.rc.left)), 0.0,
              1.0);
          if (drag_id_ == "seek") {
            ApplyLocalAction("seekFraction", t);
            Emit({{"type", ChromeValue(std::string("seekFraction"))},
                  {"value", ChromeValue(t)},
                  {"commit", ChromeValue(false)}});
          } else {
            ApplyLocalAction("volume", t * 100.0);
            Emit({{"type", "slider"},
                  {"id", ChromeValue(std::string("volume"))},
                  {"value", ChromeValue(volume_)},
                  {"commit", ChromeValue(false)}});
          }
          break;
        }
        return 0;
      }
      if (hwnd == top_.hwnd || hwnd == bottom_.hwnd || hwnd == episodes_.hwnd ||
          hwnd == live_left_.hwnd || hwnd == live_right_.hwnd || hwnd == center_play_.hwnd) {
        TRACKMOUSEEVENT tme{};
        tme.cbSize = sizeof(tme);
        tme.dwFlags = TME_LEAVE;
        tme.hwndTrack = hwnd;
        TrackMouseEvent(&tme);
        EmitPointerHold(true);
      }
      return DefWindowProcW(hwnd, msg, wParam, lParam);
    }
    case WM_MOUSELEAVE:
      if (!sheet_open_hold_) EmitPointerHold(false);
      return 0;
    case WM_RBUTTONUP: {
      // 底栏倍速右键 → 细调列表
      if (hwnd == bottom_.hwnd) {
        const int x = GET_X_LPARAM(lParam);
        const int y = GET_Y_LPARAM(lParam);
        const HitTarget* hot = HitTest(bottom_hits_, x, y);
        if (hot && hot->id == "speed") {
          HandleMoreId("speed");
          return 0;
        }
      }
      return DefWindowProcW(hwnd, msg, wParam, lParam);
    }
    case WM_LBUTTONDOWN:
    case WM_LBUTTONUP: {
      const int x = GET_X_LPARAM(lParam);
      const int y = GET_Y_LPARAM(lParam);
      RECT rc{};
      GetClientRect(hwnd, &rc);

      if (hwnd == top_.hwnd || hwnd == bottom_.hwnd || hwnd == center_play_.hwnd) {
        const std::vector<HitTarget>* bucket = nullptr;
        if (hwnd == top_.hwnd) bucket = &top_hits_;
        else if (hwnd == bottom_.hwnd) bucket = &bottom_hits_;
        else bucket = &center_hits_;
        const HitTarget* hot = bucket ? HitTest(*bucket, x, y) : nullptr;
        if (msg == WM_LBUTTONDOWN) {
          SetCapture(hwnd);
          drag_id_.clear();
          if (hot && (hot->id == "seek" || hot->id == "volume")) {
            drag_id_ = hot->id;
            DispatchHit(hwnd, x, y);
          }
          return 0;
        }
        if (GetCapture() == hwnd) ReleaseCapture();
        // 拖进度松手：提交；点按钮：UP 触发
        if (!drag_id_.empty()) {
          if (drag_id_ == "volume") {
            Emit({{"type", "slider"},
                  {"id", ChromeValue(std::string("volume"))},
                  {"value", ChromeValue(volume_)},
                  {"commit", ChromeValue(true)}});
          } else if (drag_id_ == "seek") {
            Emit({{"type", ChromeValue(std::string("seekFraction"))},
                  {"value", ChromeValue(progress_)},
                  {"commit", ChromeValue(true)}});
          }
          drag_id_.clear();
          return 0;
        }
        DispatchHit(hwnd, x, y);
        EmitPointerHold(true);
        return 0;
      }
      if (hwnd == episodes_.hwnd) {
        if (msg != WM_LBUTTONUP) return 0;
        if (y < 40 && x > rc.right - 48) {
          if (episodes_close_timer_ && host_hwnd_) {
            KillTimer(host_hwnd_, episodes_close_timer_);
            episodes_close_timer_ = 0;
          }
          episodes_visible_ = false;
          Layout();
          Emit({{"type", "closeEpisodes"}});
          return 0;
        }
        const int idx = (y - 44) / 40;
        if (idx >= 0 && idx < static_cast<int>(episode_lines_.size())) {
          episode_selected_ = idx;
          Emit({{"type", "episode"},
                {"index", ChromeValue(static_cast<int64_t>(idx))}});
          InvalidateRect(hwnd, nullptr, TRUE);
        }
        return 0;
      }
      if (hwnd == live_left_.hwnd) {
        if (msg != WM_LBUTTONUP) return 0;
        const int pad = kLivePad;
        const int gW = kLiveGroupW;
        const int cW = kLiveChannelW;
        const int tabW = kLiveEpgTabW;
        const int gap = 6;
        const int x0 = pad;
        const int y0 = pad;
        const int pillH = 32;
        const int chH = 40;
        const int tabX = groups_.empty() ? (rc.right - rc.left - pad - tabW) : (x0 + gW + gap + cW + gap);
        if (x >= tabX && x < tabX + tabW) {
          epg_open_ = !epg_open_;
          Emit({{"type", "epgToggle"}, {"open", ChromeValue(epg_open_)}});
          Layout();
          return 0;
        }
        if (!groups_.empty() && x >= x0 && x < x0 + gW) {
          const int idx = (y - y0) / (pillH + 4);
          if (idx >= 0 && idx < static_cast<int>(groups_.size())) {
            group_selected_ = idx;
            Emit({{"type", "group"}, {"index", ChromeValue(static_cast<int64_t>(idx))}});
            InvalidateRect(hwnd, nullptr, TRUE);
          }
          return 0;
        }
        const int cx = groups_.empty() ? x0 : (x0 + gW + gap);
        const int cRight = groups_.empty() ? tabX - gap : (cx + cW);
        if (x >= cx && x < cRight) {
          const int idx = (y - y0) / (chH + 2);
          if (idx >= 0 && idx < static_cast<int>(channels_.size())) {
            channel_selected_ = idx;
            Emit({{"type", "channel"}, {"index", ChromeValue(static_cast<int64_t>(idx))}});
            Emit({{"type", "liveLeft"}, {"index", ChromeValue(static_cast<int64_t>(idx))}});
            InvalidateRect(hwnd, nullptr, TRUE);
          }
          return 0;
        }
        if (epg_open_) {
          const int ex = tabX + tabW + gap;
          if (x >= ex) {
            const int dayY = y0 + 22;
            if (y >= dayY && y < dayY + 24) {
              const int idx = (x - ex) / 56;
              if (idx >= 0 && idx < static_cast<int>(epg_days_.size())) {
                epg_day_selected_ = idx;
                Emit({{"type", "epgDay"}, {"index", ChromeValue(static_cast<int64_t>(idx))}});
                InvalidateRect(hwnd, nullptr, TRUE);
              }
            } else if (y >= dayY + 28) {
              const int idx = (y - (dayY + 28)) / 30;
              if (idx >= 0 && idx < static_cast<int>(epg_programs_.size())) {
                epg_program_selected_ = idx;
                Emit({{"type", "epg"}, {"index", ChromeValue(static_cast<int64_t>(idx))}});
                InvalidateRect(hwnd, nullptr, TRUE);
              }
            }
          }
        }
        return 0;
      }
      if (hwnd == live_right_.hwnd) {
        if (msg != WM_LBUTTONUP) return 0;
        const int idx = (y - 48) / 50;
        if (idx >= 0 && idx < static_cast<int>(live_right_items_.size())) {
          Emit({{"type", ChromeValue(std::string("liveRight"))},
                {"index", ChromeValue(static_cast<int64_t>(idx))},
                {"id", ChromeValue(live_right_items_[idx].id)}});
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

void Win7ChromeShell::ApplyDanmaku(const ChromeMap& args_ref) {
  const ChromeMap* args = &args_ref;
  if (HasKey(*args, "enabled"))
    danmaku_enabled_ = GetBool(*args, "enabled", danmaku_enabled_);
  if (HasKey(*args, "fontSize"))
    danmaku_font_ = GetDouble(*args, "fontSize", danmaku_font_);
  if (HasKey(*args, "opacity"))
    danmaku_opacity_ = GetDouble(*args, "opacity", danmaku_opacity_);
  if (HasKey(*args, "durationMs"))
    danmaku_duration_ms_ = GetInt(*args, "durationMs", danmaku_duration_ms_);
  if (HasKey(*args, "fixedDurationMs"))
    danmaku_fixed_ms_ = GetInt(*args, "fixedDurationMs", danmaku_fixed_ms_);
  else if (HasKey(*args, "fixedMs"))
    danmaku_fixed_ms_ = GetInt(*args, "fixedMs", danmaku_fixed_ms_);
  if (HasKey(*args, "rows"))
    danmaku_rows_ = GetInt(*args, "rows", danmaku_rows_);
  if (HasKey(*args, "showScroll"))
    danmaku_show_scroll_ = GetBool(*args, "showScroll", danmaku_show_scroll_);
  if (HasKey(*args, "showTop"))
    danmaku_show_top_ = GetBool(*args, "showTop", danmaku_show_top_);
  if (HasKey(*args, "showBottom"))
    danmaku_show_bottom_ = GetBool(*args, "showBottom", danmaku_show_bottom_);
  if (HasKey(*args, "showReverse"))
    danmaku_show_reverse_ = GetBool(*args, "showReverse", danmaku_show_reverse_);
  if (HasKey(*args, "showPositioned"))
    danmaku_show_positioned_ = GetBool(*args, "showPositioned", danmaku_show_positioned_);
  if (HasKey(*args, "showSpecial"))
    danmaku_show_special_ = GetBool(*args, "showSpecial", danmaku_show_special_);
  if (HasKey(*args, "bold")) danmaku_bold_ = GetBool(*args, "bold", danmaku_bold_);
  if (HasKey(*args, "maxOnScreen"))
    danmaku_max_on_screen_ = GetInt(*args, "maxOnScreen", danmaku_max_on_screen_);
  if (HasKey(*args, "scrollArea"))
    danmaku_scroll_area_ = GetDouble(*args, "scrollArea", danmaku_scroll_area_);

  // items：每行 time|content|mode|color|size
  if (HasKey(*args, "items")) {
    danmaku_items_.clear();
    for (const auto& line : GetUtf8List(*args, "items")) {
      if (line.empty()) continue;
      std::vector<std::string> cols;
      size_t cs = 0;
      while (cs <= line.size()) {
        size_t c = line.find('|', cs);
        if (c == std::string::npos) {
          cols.push_back(line.substr(cs));
          break;
        }
        cols.push_back(line.substr(cs, c - cs));
        cs = c + 1;
      }
      while (cols.size() < 5) cols.push_back("");
      DanmakuItem d;
      d.time = cols[0].empty() ? 0 : std::strtod(cols[0].c_str(), nullptr);
      d.content = Utf8ToWide(cols[1]);
      d.mode = cols[2].empty() ? 1 : std::atoi(cols[2].c_str());
      d.color = cols[3].empty() ? 0xFFFFFF : std::atoi(cols[3].c_str());
      d.size = cols[4].empty() ? 25 : std::atoi(cols[4].c_str());
      if (!d.content.empty()) danmaku_items_.push_back(std::move(d));
    }
    std::sort(danmaku_items_.begin(), danmaku_items_.end(),
              [](const DanmakuItem& a, const DanmakuItem& b) { return a.time < b.time; });
  }
  if (enabled_) LayoutDanmaku();
  if (danmaku_hwnd_) InvalidateRect(danmaku_hwnd_, nullptr, FALSE);
}

void Win7ChromeShell::ApplySheet(const ChromeMap& args_ref) {
  const ChromeMap* args = &args_ref;
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

bool Win7ChromeShell::ApplyUpdate(const ChromeMap& args_ref) {
  const ChromeMap* args = &args_ref;
  bool need_layout = false;
  auto mark_layout_if = [&](bool changed) {
    if (changed) need_layout = true;
  };
  if (HasKey(*args, "mode")) {
    const auto next = GetString(*args, "mode");
    if (next != mode_) {
      volume_expanded_ = false;
      need_layout = true;
    }
    mode_ = next;
  }
  // 矩形用扁平字段（适配层从 Dart map 展开）：anchorLeft/Top/Width/Height
  if (HasKey(*args, "anchorLeft") || HasKey(*args, "anchorWidth")) {
    const double l = GetDouble(*args, "anchorLeft");
    const double t = GetDouble(*args, "anchorTop");
    const double w = GetDouble(*args, "anchorWidth");
    const double h = GetDouble(*args, "anchorHeight");
    mark_layout_if(std::abs(l - anchor_screen_l_) > 0.5 || std::abs(t - anchor_screen_t_) > 0.5 ||
                   std::abs(w - anchor_screen_w_) > 0.5 || std::abs(h - anchor_screen_h_) > 0.5);
    anchor_screen_l_ = l;
    anchor_screen_t_ = t;
    anchor_screen_w_ = w;
    anchor_screen_h_ = h;
    anchor_valid_ = anchor_screen_w_ >= 8 && anchor_screen_h_ >= 8;
  }
  if (HasKey(*args, "surfaceLeft") || HasKey(*args, "surfaceWidth")) {
    const double l = GetDouble(*args, "surfaceLeft");
    const double t = GetDouble(*args, "surfaceTop");
    const double w = GetDouble(*args, "surfaceWidth");
    const double h = GetDouble(*args, "surfaceHeight");
    mark_layout_if(std::abs(l - surface_screen_l_) > 0.5 || std::abs(t - surface_screen_t_) > 0.5 ||
                   std::abs(w - surface_screen_w_) > 0.5 || std::abs(h - surface_screen_h_) > 0.5);
    surface_screen_l_ = l;
    surface_screen_t_ = t;
    surface_screen_w_ = w;
    surface_screen_h_ = h;
    surface_valid_ = surface_screen_w_ >= 8 && surface_screen_h_ >= 8;
  }
  if (HasKey(*args, "volume")) volume_ = GetDouble(*args, "volume", volume_);
  if (HasKey(*args, "showDirect")) show_direct_ = GetBool(*args, "showDirect");
  if (HasKey(*args, "directOn")) direct_on_ = GetBool(*args, "directOn");
  if (HasKey(*args, "miniActive")) mini_active_ = GetBool(*args, "miniActive");
  if (HasKey(*args, "title")) title_ = Utf8ToWide(GetString(*args, "title"));
  if (HasKey(*args, "subtitle"))
    subtitle_ = Utf8ToWide(GetString(*args, "subtitle"));
  if (HasKey(*args, "resolution")) {
    const auto res = GetString(*args, "resolution");
    if (!res.empty()) subtitle_ = L"[ " + Utf8ToWide(res) + L" ]";
  }
  if (HasKey(*args, "clock")) clock_ = Utf8ToWide(GetString(*args, "clock"));
  if (HasKey(*args, "endsAt")) ends_at_ = Utf8ToWide(GetString(*args, "endsAt"));
  if (HasKey(*args, "positionLabel"))
    pos_label_ = Utf8ToWide(GetString(*args, "positionLabel"));
  if (HasKey(*args, "durationLabel"))
    dur_label_ = Utf8ToWide(GetString(*args, "durationLabel"));
  if (HasKey(*args, "channelNo"))
    channel_no_ = Utf8ToWide(GetString(*args, "channelNo"));
  if (HasKey(*args, "channelName"))
    channel_name_ = Utf8ToWide(GetString(*args, "channelName"));
  if (HasKey(*args, "channelProgram"))
    channel_prog_ = Utf8ToWide(GetString(*args, "channelProgram"));
  if (HasKey(*args, "channelTicker"))
    channel_ticker_ = Utf8ToWide(GetString(*args, "channelTicker"));
  if (HasKey(*args, "channelText")) {
    // 旧扁平频道条文案 → 拆到 name
    channel_name_ = Utf8ToWide(GetString(*args, "channelText"));
  }

  if (HasKey(*args, "episodes"))
    episode_lines_ = GetStringList(*args, "episodes");
  if (HasKey(*args, "episodeSelected"))
    episode_selected_ = GetInt(*args, "episodeSelected", -1);
  if (HasKey(*args, "groups")) groups_ = GetStringList(*args, "groups");
  if (HasKey(*args, "groupSelected"))
    group_selected_ = GetInt(*args, "groupSelected", -1);
  if (HasKey(*args, "channels")) channels_ = GetStringList(*args, "channels");
  if (HasKey(*args, "channelSelected"))
    channel_selected_ = GetInt(*args, "channelSelected", -1);
  // 兼容旧扁平 liveLeft
  if (HasKey(*args, "liveLeft")) {
    const auto flat = GetStringList(*args, "liveLeft");
    if (channels_.empty()) channels_ = flat;
    if (HasKey(*args, "liveLeftSelected"))
      channel_selected_ = GetInt(*args, "liveLeftSelected", -1);
  }
  if (HasKey(*args, "epgDays")) epg_days_ = GetStringList(*args, "epgDays");
  if (HasKey(*args, "epgDaySelected"))
    epg_day_selected_ = GetInt(*args, "epgDaySelected", 0);
  if (HasKey(*args, "epgPrograms"))
    epg_programs_ = GetStringList(*args, "epgPrograms");
  if (HasKey(*args, "epgProgramSelected"))
    epg_program_selected_ = GetInt(*args, "epgProgramSelected", -1);

  if (HasKey(*args, "liveRightItems")) {
    live_right_items_ = ParseLineItems(*args, "liveRightItems");
  } else if (HasKey(*args, "liveRight")) {
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
  if (HasKey(*args, "moreItems"))
    more_items_ = ParseLineItems(*args, "moreItems");

  auto set_vis = [&](bool& field, const char* key) {
    if (!HasKey(*args, key)) return;
    const bool v = GetBool(*args, key, field);
    mark_layout_if(v != field);
    field = v;
  };
  set_vis(top_visible_, "top");
  set_vis(bottom_visible_, "bottom");
  set_vis(episodes_visible_, "episodesVisible");
  set_vis(live_left_visible_, "liveLeftVisible");
  set_vis(live_right_visible_, "liveRightVisible");
  set_vis(channel_visible_, "channelVisible");
  set_vis(center_visible_, "centerVisible");
  if (HasKey(*args, "epgOpen")) {
    const bool v = GetBool(*args, "epgOpen", epg_open_);
    mark_layout_if(v != epg_open_);
    epg_open_ = v;
  }
  playing_ = GetBool(*args, "playing", playing_);
  buffering_ = GetBool(*args, "buffering", buffering_);
  progress_ = GetDouble(*args, "progress", progress_);
  if (HasKey(*args, "buffered")) buffered_ = GetDouble(*args, "buffered", buffered_);
  if (HasKey(*args, "positionSec"))
    position_sec_ = GetDouble(*args, "positionSec", position_sec_);
  else if (HasKey(*args, "position"))
    position_sec_ = GetDouble(*args, "position", position_sec_);
  rate_ = GetDouble(*args, "rate", rate_);
  if (HasKey(*args, "openingSec")) opening_sec_ = GetInt(*args, "openingSec", opening_sec_);
  if (HasKey(*args, "endingSec")) ending_sec_ = GetInt(*args, "endingSec", ending_sec_);
  if (HasKey(*args, "aspectIdx")) aspect_idx_ = GetInt(*args, "aspectIdx", aspect_idx_);
  if (HasKey(*args, "aspect")) {
    const auto k = GetString(*args, "aspect");
    if (k == "fill") aspect_idx_ = 1;
    else if (k == "zoom") aspect_idx_ = 2;
    else if (k == "16:9") aspect_idx_ = 3;
    else if (k == "4:3") aspect_idx_ = 4;
    else aspect_idx_ = 0;
  }
  if (HasKey(*args, "decode") || HasKey(*args, "decodeMode")) {
    const auto k = HasKey(*args, "decode") ? GetString(*args, "decode") : GetString(*args, "decodeMode");
    if (k == "soft") decode_idx_ = 1;
    else if (k == "hard") decode_idx_ = 2;
    else decode_idx_ = 0;
  }
  // showDirect 仅由 Flutter 显式传入，不与 decode 互相覆盖
  if (HasKey(*args, "actions")) actions_ = GetUtf8List(*args, "actions");

  /* nested danmaku: call ApplyDanmaku separately */
  return need_layout;
}


void Win7ChromeShell::LoadDemoVodFullscreen() {
  mode_ = "vod";
  title_ = L"云深不知梦 · 22";
  subtitle_ = L"[ 864 x 368 ]";
  clock_ = L"08:08:01";
  ends_at_ = L"Ends at 08:24";
  pos_label_ = L"00:02:46";
  dur_label_ = L"00:19:06";
  progress_ = 166.0 / 1146.0;
  playing_ = true;
  buffering_ = false;
  rate_ = 1.0;
  opening_sec_ = 145;
  ending_sec_ = 176;
  volume_ = 80;
  aspect_idx_ = 0;
  decode_idx_ = 0;
  show_direct_ = true;
  direct_on_ = false;
  loop_skip_ = true;
  top_visible_ = true;
  bottom_visible_ = true;
  episodes_visible_ = false;
  center_visible_ = true;
  episode_lines_ = {L"第21集", L"第22集", L"第23集", L"第24集"};
  episode_selected_ = 1;
  more_items_.clear();
  auto addMore = [&](const char* id, const wchar_t* label, RowIcon icon, bool toggle = false,
                     bool on = false, const wchar_t* trailing = L"") {
    LineItem it;
    it.id = id;
    it.label = label;
    it.icon = icon;
    it.toggle = toggle;
    it.on = on;
    it.chevron = !toggle;
    it.trailing = trailing ? trailing : L"";
    more_items_.push_back(std::move(it));
  };
  addMore("videoEq", L"画面调色", RowIcon::Tune);
  addMore("audioFx", L"音频效果", RowIcon::Equalizer);
  addMore("repeat", L"循环播放视频", RowIcon::Repeat, true, repeat_one_);
  addMore("ambient", L"氛围模式", RowIcon::Sunny, true, ambient_on_);
  addMore("danmakuSettings", L"弹幕设置", RowIcon::Tune);
  addMore("sleep", L"休眠定时器", RowIcon::Bedtime, false, false, L"关闭");
  addMore("playInfo", L"播放信息", RowIcon::Info);
  addMore("exit", L"退出全屏", RowIcon::FullscreenExit);
  SetEnabled(true);
}

void Win7ChromeShell::LoadDemoVodInline() {
  mode_ = "vod_inline";
  pos_label_ = L"02:28";
  dur_label_ = L"19:06";
  progress_ = 148.0 / 1146.0;
  playing_ = true;
  buffering_ = false;
  bottom_visible_ = true;
  top_visible_ = false;
  center_visible_ = false;
  episodes_visible_ = false;
  show_direct_ = true;
  direct_on_ = false;
  mini_active_ = false;
  volume_ = 80;
  volume_expanded_ = false;
  more_items_.clear();
  {
    LineItem d;
    d.id = "danmaku";
    d.label = L"弹幕";
    d.icon = RowIcon::Subtitles;
    d.toggle = true;
    d.on = danmaku_enabled_;
    more_items_.push_back(std::move(d));
  }
  {
    LineItem s;
    s.id = "danmakuSettings";
    s.label = L"弹幕设置";
    s.icon = RowIcon::Tune;
    s.chevron = true;
    more_items_.push_back(std::move(s));
  }
  {
    LineItem w;
    w.id = "expandWindow";
    w.label = L"铺满当前窗口";
    w.icon = RowIcon::FullscreenExit;
    more_items_.push_back(std::move(w));
  }
  {
    LineItem d;
    d.id = "expandDisplay";
    d.label = L"占满整块屏幕";
    d.icon = RowIcon::FullscreenExit;
    more_items_.push_back(std::move(d));
  }
  // 宿主客户区演示锚点：底栏贴底、画面区上方
  HWND host = HostHwnd();
  RECT crc{};
  if (host) GetClientRect(host, &crc);
  const int W = std::max(640, static_cast<int>(crc.right - crc.left));
  const int H = std::max(400, static_cast<int>(crc.bottom - crc.top));
  const int bar = 72;
  anchor_screen_l_ = 0;
  anchor_screen_t_ = H - bar;
  anchor_screen_w_ = W;
  anchor_screen_h_ = bar;
  anchor_valid_ = true;
  surface_screen_l_ = 0;
  surface_screen_t_ = 0;
  surface_screen_w_ = W;
  surface_screen_h_ = H - bar;
  surface_valid_ = true;
  SetEnabled(true);
}

void Win7ChromeShell::LoadDemoLive() {
  mode_ = "live";
  // 清掉点播态，避免顶底栏/中心键叠在直播上
  top_visible_ = false;
  bottom_visible_ = false;
  center_visible_ = false;
  episodes_visible_ = false;
  title_ = L"直播";
  channel_no_ = L"002";
  channel_name_ = L"鳳凰衛視中文台";
  channel_prog_ = L"08:00 ~ 09:00 鳳凰早班車";
  groups_ = {L"凤凰秀", L"咪咕央视", L"咪咕卫视", L"咪咕体育", L"收藏"};
  group_selected_ = 0;
  channels_ = {L"001 鳳凰衛視資訊台", L"002 鳳凰衛視中文台", L"003 鳳凰衛視香港台",
               L"004 鳳凰衛視美洲台", L"005 鳳凰衛視歐洲台"};
  channel_selected_ = 1;
  epg_days_ = {L"11-20", L"11-21", L"11-22"};
  epg_day_selected_ = 1;
  epg_programs_ = {L"07:00 新聞", L"08:00 鳳凰早班車 · 回看", L"09:00 時事直通車",
                   L"10:00 新聞", L"11:00 午間報道"};
  epg_program_selected_ = 1;
  epg_open_ = true;
  live_left_visible_ = true;
  live_right_visible_ = false;  // 左栏打开时不叠频道底条/右栏（对齐 Flutter）
  channel_visible_ = false;
  live_right_items_.clear();
  auto addR = [&](const char* id, const wchar_t* label) {
    LineItem r;
    r.id = id;
    r.label = label;
    live_right_items_.push_back(std::move(r));
  };
  addR("prevCh", L"上一频道");
  addR("nextCh", L"下一频道");
  addR("refreshEpg", L"刷新 EPG");
  addR("close", L"关闭面板");
  SetEnabled(true);
}

void Win7ChromeShell::LoadDemoLiveChannelBar() {
  LoadDemoLive();
  live_left_visible_ = false;
  live_right_visible_ = false;
  channel_visible_ = true;
  channel_no_ = L"003";
  channel_name_ = L"鳳凰衛視香港台";
  channel_prog_ = L"08:55 ~ 09:00 鳳凰氣象站";
  SetEnabled(true);
}

void Win7ChromeShell::LoadDemoLiveRight() {
  LoadDemoLive();
  live_left_visible_ = false;
  live_right_visible_ = true;
  channel_visible_ = false;
  SetEnabled(true);
}

void Win7ChromeShell::HideSheet() { CloseSheet(false); }

namespace {

const char* VkToLogicalName(WPARAM vk) {
  switch (vk) {
    case VK_ESCAPE:
      return "Escape";
    case VK_RETURN:
      return "Enter";
    case VK_SPACE:
      return "Space";
    case VK_LEFT:
      return "ArrowLeft";
    case VK_RIGHT:
      return "ArrowRight";
    case VK_UP:
      return "ArrowUp";
    case VK_DOWN:
      return "ArrowDown";
    case VK_PRIOR:
      return "PageUp";
    case VK_NEXT:
      return "PageDown";
    case VK_APPS:
      return "ContextMenu";
    case VK_BACK:
      return "GoBack";
    case VK_MEDIA_PLAY_PAUSE:
      return "MediaPlayPause";
    case VK_MEDIA_STOP:
      return "MediaStop";
    case VK_MEDIA_NEXT_TRACK:  // 0xB0
      return "MediaTrackNext";
    case VK_MEDIA_PREV_TRACK:  // 0xB1
      return "MediaTrackPrevious";
    case VK_VOLUME_UP:  // 0xAF
      return "VolumeUp";
    case VK_VOLUME_DOWN:  // 0xAE
      return "VolumeDown";
    case 0x45:
      return "KeyE";
    case 0x4D:
      return "KeyM";
    case 0x53:
      return "KeyS";
    case 0x30:
    case 0x31:
    case 0x32:
    case 0x33:
    case 0x34:
    case 0x35:
    case 0x36:
    case 0x37:
    case 0x38:
    case 0x39: {
      static thread_local char digit[8];
      snprintf(digit, sizeof(digit), "Digit%c", static_cast<char>('0' + (vk - 0x30)));
      return digit;
    }
    default:
      return nullptr;
  }
}

const char* AppCommandToLogicalName(int cmd) {
  switch (cmd) {
    case APPCOMMAND_MEDIA_PLAY_PAUSE:
      return "MediaPlayPause";
    case APPCOMMAND_MEDIA_STOP:
      return "MediaStop";
    case APPCOMMAND_MEDIA_PREVIOUSTRACK:
      return "MediaTrackPrevious";
    case APPCOMMAND_MEDIA_NEXTTRACK:
      return "MediaTrackNext";
    case APPCOMMAND_MEDIA_REWIND:
      return "MediaRewind";
    case APPCOMMAND_MEDIA_FAST_FORWARD:
      return "MediaFastForward";
    case APPCOMMAND_VOLUME_UP:
      return "VolumeUp";
    case APPCOMMAND_VOLUME_DOWN:
      return "VolumeDown";
    case APPCOMMAND_VOLUME_MUTE:
      return "VolumeMute";
    default:
      return nullptr;
  }
}

}  // namespace

LRESULT CALLBACK Win7ChromeShell::GestureWndProc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam) {
  if (msg == WM_NCCREATE) {
    auto* cs = reinterpret_cast<CREATESTRUCTW*>(lParam);
    SetWindowLongPtrW(hwnd, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(cs->lpCreateParams));
  }
  auto* self = reinterpret_cast<Win7ChromeShell*>(GetWindowLongPtrW(hwnd, GWLP_USERDATA));
  if (self) return self->OnGestureMessage(hwnd, msg, wParam, lParam);
  return DefWindowProcW(hwnd, msg, wParam, lParam);
}

LRESULT CALLBACK Win7ChromeShell::RootSubclassProc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam,
                                                   UINT_PTR /*id*/, DWORD_PTR data) {
  auto* self = reinterpret_cast<Win7ChromeShell*>(data);
  if (self && self->enabled_ && !self->sheet_kind_.empty()) {
    if (msg == WM_MOVE || msg == WM_MOVING || msg == WM_EXITSIZEMOVE) {
      self->SyncModalToHost(false);
    } else if (msg == WM_SIZE || msg == WM_SIZING) {
      self->SyncModalToHost(true);
    } else if (msg == WM_WINDOWPOSCHANGED) {
      const auto* wp = reinterpret_cast<WINDOWPOS*>(lParam);
      const bool sized = wp && !(wp->flags & SWP_NOSIZE);
      const bool moved = wp && !(wp->flags & SWP_NOMOVE);
      if (sized || moved) self->SyncModalToHost(sized);
    }
  }
  return DefSubclassProc(hwnd, msg, wParam, lParam);
}

LRESULT CALLBACK Win7ChromeShell::HostSubclassProc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam,
                                                   UINT_PTR /*id*/, DWORD_PTR data) {
  auto* self = reinterpret_cast<Win7ChromeShell*>(data);
  if (!self || !self->enabled_) {
    return DefSubclassProc(hwnd, msg, wParam, lParam);
  }
  // 窗口缩放：顶底栏/选集跟客户区重排；视频洞由 Flutter updateFrame 同步。
  if (msg == WM_SIZE) {
    self->Layout();
    if (!self->sheet_kind_.empty()) self->SyncModalToHost(true);
  }
  if (msg == WM_TIMER && wParam == kEpisodesCloseTimerId) {
    KillTimer(hwnd, kEpisodesCloseTimerId);
    self->episodes_close_timer_ = 0;
    if (self->episodes_visible_) {
      self->episodes_visible_ = false;
      self->Layout();
      self->Emit({{"type", ChromeValue(std::string("closeEpisodes"))}});
    }
    return 0;
  }
  if (msg == WM_APPCOMMAND) {
    const int cmd = GET_APPCOMMAND_LPARAM(lParam);
    const char* name = AppCommandToLogicalName(cmd);
    if (name) {
      self->Emit({{"type", ChromeValue(std::string("key"))},
                  {"logical", ChromeValue(std::string(name))},
                  {"down", ChromeValue(true)},
                  {"repeat", ChromeValue(false)},
                  {"up", ChromeValue(false)}});
      return TRUE;
    }
  }
  if (msg == WM_KEYDOWN || msg == WM_SYSKEYDOWN || msg == WM_KEYUP || msg == WM_SYSKEYUP) {
    const bool down = (msg == WM_KEYDOWN || msg == WM_SYSKEYDOWN);
    const bool repeat = down && ((lParam & (1 << 30)) != 0);
    const char* name = VkToLogicalName(wParam);
    if (name) {
      self->Emit({{"type", ChromeValue(std::string("key"))},
                  {"logical", ChromeValue(std::string(name))},
                  {"down", ChromeValue(down)},
                  {"repeat", ChromeValue(repeat)},
                  {"up", ChromeValue(!down)}});
      // 继续 DefSubclassProc：独立仓 demo 快捷键 / 宿主仍可收键；Dart 侧自行 handled
    }
  }
  return DefSubclassProc(hwnd, msg, wParam, lParam);
}

LRESULT Win7ChromeShell::OnGestureMessage(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam) {
  switch (msg) {
    case WM_PAINT: {
      PAINTSTRUCT ps;
      BeginPaint(hwnd, &ps);
      EndPaint(hwnd, &ps);
      return 0;
    }
    case WM_ERASEBKGND:
      return 1;
    case WM_TIMER:
      if (wParam == kHoldSpeedTimerId && ges_mode_ == GestureMode::Pending && !ges_moved_) {
        KillTimer(hwnd, kHoldSpeedTimerId);
        hold_speed_timer_ = 0;
        ges_mode_ = GestureMode::HoldSpeed;
        Emit({{"type", ChromeValue(std::string("holdSpeed"))},
              {"on", ChromeValue(true)}});
      }
      return 0;
    case WM_LBUTTONDOWN: {
      SetCapture(hwnd);
      RECT rc{};
      GetClientRect(hwnd, &rc);
      ges_client_w_ = rc.right - rc.left;
      ges_down_.x = GET_X_LPARAM(lParam);
      ges_down_.y = GET_Y_LPARAM(lParam);
      ges_down_tick_ = GetTickCount();
      ges_moved_ = false;
      ges_mode_ = GestureMode::Pending;
      ges_origin_progress_ = progress_;
      ges_origin_volume_ = volume_;
      if (hold_speed_timer_) KillTimer(hwnd, hold_speed_timer_);
      hold_speed_timer_ = SetTimer(hwnd, kHoldSpeedTimerId, kHoldSpeedMs, nullptr);
      EmitPointerHold(true);
      return 0;
    }
    case WM_MOUSEMOVE: {
      const int x = GET_X_LPARAM(lParam);
      const int y = GET_Y_LPARAM(lParam);
      RECT rc{};
      GetClientRect(hwnd, &rc);
      const int cw = rc.right - rc.left;

      // 无拖：悬停亮栏 + 右缘悬停开选集
      if (GetCapture() != hwnd) {
        TRACKMOUSEEVENT tme{};
        tme.cbSize = sizeof(tme);
        tme.dwFlags = TME_LEAVE;
        tme.hwndTrack = hwnd;
        TrackMouseEvent(&tme);
        Emit({{"type", ChromeValue(std::string("hover"))},
              {"x", ChromeValue(static_cast<int64_t>(x))},
              {"y", ChromeValue(static_cast<int64_t>(y))}});
        if (mode_ != "live" && !episodes_visible_ && x >= cw - kDesktopEdgeHover) {
          episodes_visible_ = true;
          if (episodes_close_timer_ && host_hwnd_) {
            KillTimer(host_hwnd_, episodes_close_timer_);
            episodes_close_timer_ = 0;
          }
          if (host_hwnd_) {
            episodes_close_timer_ =
                SetTimer(host_hwnd_, kEpisodesCloseTimerId, kEpisodesCloseMs, nullptr);
          }
          Layout();
          Emit({{"type", ChromeValue(std::string("episodes"))}});
        }
        return 0;
      }

      if (ges_mode_ == GestureMode::None) return 0;
      const int dx = x - ges_down_.x;
      const int dy = y - ges_down_.y;
      if (!ges_moved_ && (std::abs(dx) > kGestureSlop || std::abs(dy) > kGestureSlop)) {
        ges_moved_ = true;
        if (hold_speed_timer_) {
          KillTimer(hwnd, hold_speed_timer_);
          hold_speed_timer_ = 0;
        }
        if (ges_mode_ == GestureMode::Pending) {
          // 对齐 KotvFsGesture.classifyDrag：横滑 seek；竖滑按 x 四分
          if (std::abs(dx) >= std::abs(dy)) {
            ges_mode_ = GestureMode::Seek;
          } else {
            const int w = ges_client_w_ > 0 ? ges_client_w_ : cw;
            if (ges_down_.x >= (w * 3) / 4) {
              ges_mode_ = GestureMode::Volume;
            } else if (mode_ == "live") {
              // 中区留给抬手 liveFling；保持 Pending
            } else {
              ges_mode_ = GestureMode::Ep;
            }
          }
        }
      }
      if (ges_mode_ == GestureMode::Seek) {
        double total_sec = 1800.0;
        if (progress_ > 1e-6 && position_sec_ > 0) {
          total_sec = (std::max)(1.0, position_sec_ / progress_);
        }
        const double delta_frac = (dx * kSeekMsPerPx) / (total_sec * 1000.0);
        const double next = std::clamp(ges_origin_progress_ + delta_frac, 0.0, 1.0);
        progress_ = next;
        Emit({{"type", ChromeValue(std::string("seekFraction"))},
              {"value", ChromeValue(next)},
              {"commit", ChromeValue(false)}});
        InvalidateChrome();
      } else if (ges_mode_ == GestureMode::Volume) {
        const double next = std::clamp(ges_origin_volume_ - dy * 0.35, 0.0, 100.0);
        volume_ = next;
        Emit({{"type", "slider"},
              {"id", ChromeValue(std::string("volume"))},
              {"value", ChromeValue(volume_)},
              {"commit", ChromeValue(false)}});
      } else if (ges_mode_ == GestureMode::Ep) {
        // 跟手预览由 Dart 处理；此处仅标记
      }
      return 0;
    }
    case WM_LBUTTONDBLCLK: {
      Emit({{"type", ChromeValue(std::string("doubleTap"))}});
      return 0;
    }
    case WM_LBUTTONUP: {
      if (GetCapture() == hwnd) ReleaseCapture();
      if (hold_speed_timer_) {
        KillTimer(hwnd, hold_speed_timer_);
        hold_speed_timer_ = 0;
      }
      const int x = GET_X_LPARAM(lParam);
      const int dy = GET_Y_LPARAM(lParam) - ges_down_.y;
      const GestureMode mode = ges_mode_;
      ges_mode_ = GestureMode::None;
      if (mode == GestureMode::HoldSpeed) {
        Emit({{"type", ChromeValue(std::string("holdSpeed"))},
              {"on", ChromeValue(false)}});
        EmitPointerHold(false);
        return 0;
      }
      if (mode == GestureMode::Seek) {
        Emit({{"type", ChromeValue(std::string("seekFraction"))},
              {"value", ChromeValue(progress_)},
              {"commit", ChromeValue(true)}});
        EmitPointerHold(false);
        return 0;
      }
      if (mode == GestureMode::Volume) {
        Emit({{"type", "slider"},
              {"id", ChromeValue(std::string("volume"))},
              {"value", ChromeValue(volume_)},
              {"commit", ChromeValue(true)}});
        EmitPointerHold(false);
        return 0;
      }
      if (mode == GestureMode::Ep && ges_moved_) {
        if (std::abs(dy) >= 48) {
          Emit({{"type", ChromeValue(std::string(dy < 0 ? "next" : "prev"))}});
        }
        EmitPointerHold(false);
        return 0;
      }
      // 单击：右缘开选集，否则 tap（显隐栏）
      RECT rc{};
      GetClientRect(hwnd, &rc);
      if (!ges_moved_ && mode_ != "live" && x >= rc.right - kEdgeIgnore) {
        episodes_visible_ = true;
        if (episodes_close_timer_ && host_hwnd_) {
          KillTimer(host_hwnd_, episodes_close_timer_);
          episodes_close_timer_ = 0;
        }
        if (host_hwnd_) {
          episodes_close_timer_ =
              SetTimer(host_hwnd_, kEpisodesCloseTimerId, kEpisodesCloseMs, nullptr);
        }
        Layout();
        Emit({{"type", ChromeValue(std::string("episodes"))}});
      } else if (!ges_moved_) {
        Emit({{"type", ChromeValue(std::string("tap"))}});
      } else if (mode_ == "live") {
        if (std::abs(dy) >= 100) {
          Emit({{"type", ChromeValue(std::string("liveFling"))},
                {"sign", ChromeValue(static_cast<int64_t>(dy < 0 ? -1 : 1))}});
        }
      }
      EmitPointerHold(false);
      return 0;
    }
    case WM_MOUSEWHEEL: {
      const short delta = GET_WHEEL_DELTA_WPARAM(wParam);
      const bool shift = (GetKeyState(VK_SHIFT) & 0x8000) != 0;
      // classifyScroll：Shift → seek；默认音量
      if (shift) {
        const double steps = std::clamp(std::abs(delta) / 120.0, 1.0, 4.0);
        const double sign = delta > 0 ? -1.0 : 1.0;  // 上滚后退
        double total_sec = 1800.0;
        if (progress_ > 1e-6 && position_sec_ > 0) {
          total_sec = (std::max)(1.0, position_sec_ / progress_);
        }
        const double delta_frac = (sign * steps * 5.0) / total_sec;
        progress_ = std::clamp(progress_ + delta_frac, 0.0, 1.0);
        Emit({{"type", ChromeValue(std::string("seekFraction"))},
              {"value", ChromeValue(progress_)},
              {"commit", ChromeValue(true)}});
        InvalidateChrome();
      } else {
        const double steps = std::clamp(std::abs(delta) / 120.0, 1.0, 4.0);
        const double dv = (delta > 0 ? 1.0 : -1.0) * 4.0 * steps;
        volume_ = std::clamp(volume_ + dv, 0.0, 100.0);
        Emit({{"type", "slider"},
              {"id", ChromeValue(std::string("volume"))},
              {"value", ChromeValue(volume_)},
              {"commit", ChromeValue(true)}});
      }
      return 0;
    }
    case WM_MOUSELEAVE:
      EmitPointerHold(false);
      return 0;
    default:
      return DefWindowProcW(hwnd, msg, wParam, lParam);
  }
}
