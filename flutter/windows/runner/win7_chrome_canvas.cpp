#include "win7_chrome_canvas.h"

#include <algorithm>
#include <cmath>
#include <map>
#include <memory>
#include <string>
#include <vector>

#include <gdiplus.h>

namespace kotv_chrome {
namespace {

struct FontState {
  bool loaded = false;
  std::wstring text_face = L"Microsoft YaHei";
  std::wstring bold_face;  // 独立粗体字族（Noto Sans SC Bold）；空则合成粗体。
  std::wstring icon_face;
  std::map<uint64_t, HFONT> cache;
};

FontState& Fonts() {
  static FontState s;
  return s;
}

int CALLBACK EnumFound(const LOGFONTW*, const TEXTMETRICW*, DWORD, LPARAM lp) {
  *reinterpret_cast<bool*>(lp) = true;
  return 0;
}

bool HasFace(const wchar_t* face) {
  HDC dc = GetDC(nullptr);
  LOGFONTW lf{};
  lf.lfCharSet = DEFAULT_CHARSET;
  wcsncpy_s(lf.lfFaceName, face, _TRUNCATE);
  bool found = false;
  EnumFontFamiliesExW(dc, &lf, EnumFound, reinterpret_cast<LPARAM>(&found), 0);
  ReleaseDC(nullptr, dc);
  return found;
}

std::wstring AssetDir() {
  wchar_t path[MAX_PATH] = {};
  GetModuleFileNameW(nullptr, path, MAX_PATH);
  std::wstring dir(path);
  const size_t slash = dir.find_last_of(L"\\/");
  if (slash != std::wstring::npos) dir.resize(slash);
  return dir + L"\\data\\flutter_assets\\";
}

HFONT FontFor(float px, int weight, bool icon) {
  Canvas::LoadFonts();
  auto& st = Fonts();
  const int size = std::max(1, static_cast<int>(std::lround(px)));
  const bool bold = !icon && weight >= 600;
  const uint64_t key = static_cast<uint64_t>(size) | (bold ? 1ull << 32 : 0) | (icon ? 1ull << 33 : 0);
  auto it = st.cache.find(key);
  if (it != st.cache.end()) return it->second;
  std::wstring face = icon ? st.icon_face : st.text_face;
  int w = FW_NORMAL;
  if (bold) {
    if (!st.bold_face.empty()) {
      face = st.bold_face;
    } else {
      w = FW_BOLD;
    }
  }
  HFONT f = CreateFontW(-size, 0, 0, 0, w, FALSE, FALSE, FALSE, DEFAULT_CHARSET, OUT_TT_PRECIS,
                        CLIP_DEFAULT_PRECIS, ANTIALIASED_QUALITY, DEFAULT_PITCH, face.c_str());
  st.cache[key] = f;
  return f;
}

std::wstring CodepointString(uint32_t cp) {
  std::wstring s;
  if (cp >= 0x10000) {
    cp -= 0x10000;
    s.push_back(static_cast<wchar_t>(0xD800 + (cp >> 10)));
    s.push_back(static_cast<wchar_t>(0xDC00 + (cp & 0x3FF)));
  } else {
    s.push_back(static_cast<wchar_t>(cp));
  }
  return s;
}

// 遮罩用的临时 DIB（白字黑底，取蓝通道为覆盖率）。
struct Scratch {
  HDC dc = nullptr;
  HBITMAP bmp = nullptr;
  HGDIOBJ old = nullptr;
  uint32_t* bits = nullptr;
  int w = 0;
  int h = 0;
  bool Ensure(int nw, int nh) {
    if (dc && nw <= w && nh <= h) return true;
    if (dc) {
      SelectObject(dc, old);
      DeleteObject(bmp);
      DeleteDC(dc);
      dc = nullptr;
    }
    w = std::max(nw, w);
    h = std::max(nh, h);
    BITMAPINFO bi{};
    bi.bmiHeader.biSize = sizeof(bi.bmiHeader);
    bi.bmiHeader.biWidth = w;
    bi.bmiHeader.biHeight = -h;
    bi.bmiHeader.biPlanes = 1;
    bi.bmiHeader.biBitCount = 32;
    bi.bmiHeader.biCompression = BI_RGB;
    dc = CreateCompatibleDC(nullptr);
    void* p = nullptr;
    bmp = CreateDIBSection(dc, &bi, DIB_RGB_COLORS, &p, nullptr, 0);
    if (!bmp) {
      DeleteDC(dc);
      dc = nullptr;
      return false;
    }
    bits = static_cast<uint32_t*>(p);
    old = SelectObject(dc, bmp);
    SetBkMode(dc, TRANSPARENT);
    SetTextColor(dc, RGB(255, 255, 255));
    return true;
  }
};

Scratch& Mask() {
  static Scratch s;
  return s;
}

// 进程退出时 GDI+ 可能已先关闭，缓存故意不析构。
std::map<std::string, std::unique_ptr<Gdiplus::Bitmap>>& Images() {
  static auto* m = new std::map<std::string, std::unique_ptr<Gdiplus::Bitmap>>();
  return *m;
}

Gdiplus::Color ToColor(Argb c) {
  return Gdiplus::Color(static_cast<BYTE>(c >> 24), static_cast<BYTE>(c >> 16), static_cast<BYTE>(c >> 8),
                        static_cast<BYTE>(c));
}

void AddRound(Gdiplus::GraphicsPath& path, const Gdiplus::RectF& r, float radius) {
  const float d = std::min({radius * 2, r.Width, r.Height});
  if (d <= 0.5f) {
    path.AddRectangle(r);
    return;
  }
  path.AddArc(r.X, r.Y, d, d, 180, 90);
  path.AddArc(r.X + r.Width - d, r.Y, d, d, 270, 90);
  path.AddArc(r.X + r.Width - d, r.Y + r.Height - d, d, d, 0, 90);
  path.AddArc(r.X, r.Y + r.Height - d, d, d, 90, 90);
  path.CloseFigure();
}

}  // namespace

uint32_t IconByName(const std::string& n) {
  static const std::map<std::string, uint32_t> kMap = {
      {"tune", 0xe683},
      {"equalizer", 0xe236},
      {"repeat", 0xe51f},
      {"wb_sunny_outlined", 0xf4bc},
      {"graphic_eq", 0xe2e3},
      {"skip_next_outlined", 0xf3a0},
      {"playlist_play", 0xe4d4},
      {"manage_search", 0xe3c7},
      {"bedtime_outlined", 0xeecb},
      {"cast", 0xe144},
      {"picture_in_picture_alt", 0xe4c2},
      {"auto_awesome", 0xe0b7},
      {"refresh", 0xe514},
      {"favorite_border", 0xe25c},
      {"favorite", 0xe25b},
      {"layers_outlined", 0xf157},
      {"info_outline", 0xe33d},
      {"fullscreen_exit", 0xe2cc},
      {"fullscreen", 0xe2cb},
      {"closed_caption_off_outlined", 0xef5c},
      {"folder_open_outlined", 0xf090},
      {"search", 0xe567},
      {"menu_open", 0xe3de},
      {"smart_display_outlined", 0xf3a6},
      {"subtitles_outlined", 0xf3fd},
      {"audiotrack", 0xe0b6},
      {"videocam_outlined", 0xf48c},
      {"album_outlined", 0xee67},
      {"check", 0xe156},
      {"close", 0xe16a},
  };
  auto it = kMap.find(n);
  return it == kMap.end() ? 0 : it->second;
}

void Canvas::LoadFonts() {
  auto& st = Fonts();
  if (st.loaded) return;
  st.loaded = true;
  const std::wstring dir = AssetDir();
  AddFontResourceExW((dir + L"assets\\fonts\\NotoSansSC-Regular.otf").c_str(), FR_PRIVATE, nullptr);
  AddFontResourceExW((dir + L"assets\\fonts\\NotoSansSC-Bold.otf").c_str(), FR_PRIVATE, nullptr);
  AddFontResourceExW((dir + L"fonts\\MaterialIcons-Regular.otf").c_str(), FR_PRIVATE, nullptr);
  if (HasFace(L"Noto Sans SC")) {
    st.text_face = L"Noto Sans SC";
    if (HasFace(L"Noto Sans SC Bold")) st.bold_face = L"Noto Sans SC Bold";
  } else if (HasFace(L"Microsoft YaHei UI")) {
    st.text_face = L"Microsoft YaHei UI";
  }
  if (HasFace(L"Material Icons")) {
    st.icon_face = L"Material Icons";
  } else if (HasFace(L"MaterialIcons")) {
    st.icon_face = L"MaterialIcons";
  }
}

Canvas::Canvas() = default;

Canvas::~Canvas() {
  End();
  if (dc_) {
    SelectObject(dc_, old_);
    DeleteObject(bmp_);
    DeleteDC(dc_);
  }
}

bool Canvas::Begin(int w, int h) {
  if (w <= 0 || h <= 0) return false;
  End();
  if (!dc_ || w > cap_w_ || h > cap_h_ || w * 2 < cap_w_ || h * 2 < cap_h_) {
    if (dc_) {
      SelectObject(dc_, old_);
      DeleteObject(bmp_);
      DeleteDC(dc_);
      dc_ = nullptr;
    }
    BITMAPINFO bi{};
    bi.bmiHeader.biSize = sizeof(bi.bmiHeader);
    bi.bmiHeader.biWidth = w;
    bi.bmiHeader.biHeight = -h;
    bi.bmiHeader.biPlanes = 1;
    bi.bmiHeader.biBitCount = 32;
    bi.bmiHeader.biCompression = BI_RGB;
    dc_ = CreateCompatibleDC(nullptr);
    void* p = nullptr;
    bmp_ = CreateDIBSection(dc_, &bi, DIB_RGB_COLORS, &p, nullptr, 0);
    if (!bmp_) {
      DeleteDC(dc_);
      dc_ = nullptr;
      return false;
    }
    bits_ = static_cast<uint32_t*>(p);
    old_ = SelectObject(dc_, bmp_);
    cap_w_ = w;
    cap_h_ = h;
  }
  w_ = w;
  h_ = h;
  has_clip_ = false;
  for (int y = 0; y < h_; ++y) std::fill_n(bits_ + y * cap_w_, w_, 0u);
  gbmp_ = std::make_unique<Gdiplus::Bitmap>(w_, h_, cap_w_ * 4, PixelFormat32bppPARGB,
                                            reinterpret_cast<BYTE*>(bits_));
  g_ = std::make_unique<Gdiplus::Graphics>(gbmp_.get());
  g_->SetSmoothingMode(Gdiplus::SmoothingModeAntiAlias);
  g_->SetPixelOffsetMode(Gdiplus::PixelOffsetModeHalf);
  return true;
}

void Canvas::End() {
  Flush();
  g_.reset();
  gbmp_.reset();
}

void Canvas::Flush() {
  if (g_) g_->Flush(Gdiplus::FlushIntentionSync);
}

void Canvas::ClearOutside(const RECT& keep) {
  if (!bits_) return;
  const int l = std::clamp(static_cast<int>(keep.left), 0, w_);
  const int r = std::clamp(static_cast<int>(keep.right), 0, w_);
  const int t = std::clamp(static_cast<int>(keep.top), 0, h_);
  const int b = std::clamp(static_cast<int>(keep.bottom), 0, h_);
  for (int y = 0; y < h_; ++y) {
    uint32_t* row = bits_ + y * cap_w_;
    if (y < t || y >= b || r <= l) {
      std::fill_n(row, w_, 0u);
      continue;
    }
    std::fill_n(row, l, 0u);
    std::fill_n(row + r, w_ - r, 0u);
  }
}

void Canvas::SetClip(const RECT& rc) {
  clip_ = rc;
  has_clip_ = true;
  if (g_) {
    g_->SetClip(Gdiplus::Rect(rc.left, rc.top, rc.right - rc.left, rc.bottom - rc.top));
  }
}

void Canvas::ClearClip() {
  has_clip_ = false;
  if (g_) g_->ResetClip();
}

void Canvas::Fill(const RECT& rc, Argb c) {
  if (!g_ || (c >> 24) == 0) return;
  Gdiplus::SolidBrush b(ToColor(c));
  g_->SetSmoothingMode(Gdiplus::SmoothingModeNone);
  g_->FillRectangle(&b, static_cast<INT>(rc.left), static_cast<INT>(rc.top),
                    static_cast<INT>(rc.right - rc.left), static_cast<INT>(rc.bottom - rc.top));
  g_->SetSmoothingMode(Gdiplus::SmoothingModeAntiAlias);
}

void Canvas::RoundRect(const RECT& rc, float radius, Argb fill, Argb border, float border_w) {
  if (!g_) return;
  Gdiplus::RectF r(static_cast<float>(rc.left), static_cast<float>(rc.top),
                   static_cast<float>(rc.right - rc.left), static_cast<float>(rc.bottom - rc.top));
  if (r.Width <= 0 || r.Height <= 0) return;
  if (fill >> 24) {
    Gdiplus::GraphicsPath path;
    AddRound(path, r, radius);
    Gdiplus::SolidBrush b(ToColor(fill));
    g_->FillPath(&b, &path);
  }
  if ((border >> 24) && border_w > 0) {
    const float h = border_w / 2;
    Gdiplus::RectF in(r.X + h, r.Y + h, r.Width - border_w, r.Height - border_w);
    Gdiplus::GraphicsPath path;
    AddRound(path, in, std::max(0.0f, radius - h));
    Gdiplus::Pen pen(ToColor(border), border_w);
    g_->DrawPath(&pen, &path);
  }
}

void Canvas::Circle(float cx, float cy, float r, Argb fill) {
  if (!g_ || (fill >> 24) == 0 || r <= 0) return;
  Gdiplus::SolidBrush b(ToColor(fill));
  g_->FillEllipse(&b, cx - r, cy - r, r * 2, r * 2);
}

void Canvas::Line(float x0, float y0, float x1, float y1, float w, Argb c) {
  if (!g_ || (c >> 24) == 0) return;
  Gdiplus::Pen pen(ToColor(c), w);
  g_->DrawLine(&pen, x0, y0, x1, y1);
}

void Canvas::VGradient(const RECT& rc, Argb top, Argb bottom) {
  if (!g_ || rc.bottom <= rc.top) return;
  Gdiplus::RectF r(static_cast<float>(rc.left), static_cast<float>(rc.top) - 0.5f,
                   static_cast<float>(rc.right - rc.left), static_cast<float>(rc.bottom - rc.top) + 1.0f);
  Gdiplus::LinearGradientBrush b(r, ToColor(top), ToColor(bottom), Gdiplus::LinearGradientModeVertical);
  g_->SetSmoothingMode(Gdiplus::SmoothingModeNone);
  g_->FillRectangle(&b, static_cast<INT>(rc.left), static_cast<INT>(rc.top),
                    static_cast<INT>(rc.right - rc.left), static_cast<INT>(rc.bottom - rc.top));
  g_->SetSmoothingMode(Gdiplus::SmoothingModeAntiAlias);
}

void Canvas::Arc(float cx, float cy, float r, float start_deg, float sweep_deg, float w, Argb c) {
  if (!g_ || (c >> 24) == 0 || r <= 0 || sweep_deg == 0) return;
  Gdiplus::Pen pen(ToColor(c), w);
  g_->DrawArc(&pen, cx - r, cy - r, r * 2, r * 2, start_deg, sweep_deg);
}

bool Canvas::HasImage(const std::string& key) {
  auto& m = Images();
  return m.find(key) != m.end();
}

void Canvas::PutImage(const std::string& key, int w, int h, const uint8_t* rgba, size_t len) {
  if (key.empty() || w <= 0 || h <= 0 || !rgba || len < static_cast<size_t>(w) * h * 4) return;
  auto bmp = std::make_unique<Gdiplus::Bitmap>(w, h, PixelFormat32bppPARGB);
  Gdiplus::Rect all(0, 0, w, h);
  Gdiplus::BitmapData data{};
  if (bmp->LockBits(&all, Gdiplus::ImageLockModeWrite, PixelFormat32bppPARGB, &data) != Gdiplus::Ok) return;
  for (int y = 0; y < h; ++y) {
    auto* row = reinterpret_cast<uint32_t*>(static_cast<uint8_t*>(data.Scan0) + y * data.Stride);
    const uint8_t* s = rgba + static_cast<size_t>(y) * w * 4;
    for (int x = 0; x < w; ++x, s += 4) {
      const uint32_t a = s[3];
      row[x] = (a << 24) | ((s[0] * a / 255) << 16) | ((s[1] * a / 255) << 8) | (s[2] * a / 255);
    }
  }
  bmp->UnlockBits(&data);
  auto& m = Images();
  // 台标一般几十到几百张；超量时整体清掉重建，避免常驻内存无界增长。
  if (m.size() > 512) m.clear();
  m[key] = std::move(bmp);
}

bool Canvas::Image(const RECT& rc, const std::string& key, float radius) {
  if (!g_) return false;
  auto& m = Images();
  auto it = m.find(key);
  if (it == m.end() || !it->second) return false;
  Gdiplus::Bitmap* bmp = it->second.get();
  const float bw = static_cast<float>(bmp->GetWidth());
  const float bh = static_cast<float>(bmp->GetHeight());
  const float rw = static_cast<float>(rc.right - rc.left);
  const float rh = static_cast<float>(rc.bottom - rc.top);
  if (bw <= 0 || bh <= 0 || rw <= 0 || rh <= 0) return false;
  const float s = std::min(rw / bw, rh / bh);
  const float dw = bw * s;
  const float dh = bh * s;
  const Gdiplus::RectF dst(rc.left + (rw - dw) / 2, rc.top + (rh - dh) / 2, dw, dh);
  Gdiplus::GraphicsPath path;
  AddRound(path, Gdiplus::RectF(static_cast<float>(rc.left), static_cast<float>(rc.top), rw, rh), radius);
  Gdiplus::Region old;
  g_->GetClip(&old);
  g_->SetClip(&path, Gdiplus::CombineModeIntersect);
  g_->SetInterpolationMode(Gdiplus::InterpolationModeHighQualityBicubic);
  g_->DrawImage(bmp, dst);
  g_->SetClip(&old);
  return true;
}

void Canvas::Composite(const RECT& dst, const uint32_t* mask, int mask_stride, Argb c) {
  const uint32_t ca = c >> 24;
  const uint32_t cr = (c >> 16) & 0xFF;
  const uint32_t cg = (c >> 8) & 0xFF;
  const uint32_t cb = c & 0xFF;
  RECT lim{0, 0, w_, h_};
  if (has_clip_) IntersectRect(&lim, &lim, &clip_);
  for (int y = dst.top; y < dst.bottom; ++y) {
    if (y < lim.top || y >= lim.bottom) continue;
    const uint32_t* m = mask + (y - dst.top) * mask_stride;
    uint32_t* d = bits_ + y * cap_w_;
    for (int x = dst.left; x < dst.right; ++x) {
      if (x < lim.left || x >= lim.right) continue;
      const uint32_t px = m[x - dst.left];
      const uint32_t cov = std::max({px & 0xFF, (px >> 8) & 0xFF, (px >> 16) & 0xFF});
      if (!cov) continue;
      const uint32_t a = cov * ca / 255;
      if (!a) continue;
      const uint32_t inv = 255 - a;
      const uint32_t o = d[x];
      const uint32_t oa = o >> 24, orr = (o >> 16) & 0xFF, og = (o >> 8) & 0xFF, ob = o & 0xFF;
      const uint32_t na = a + oa * inv / 255;
      const uint32_t nr = cr * a / 255 + orr * inv / 255;
      const uint32_t ng = cg * a / 255 + og * inv / 255;
      const uint32_t nb = cb * a / 255 + ob * inv / 255;
      d[x] = (std::min(na, 255u) << 24) | (std::min(nr, 255u) << 16) | (std::min(ng, 255u) << 8) |
             std::min(nb, 255u);
    }
  }
}

int Canvas::Text(const RECT& rc, const std::wstring& s, Argb c, float px, int weight, UINT fmt) {
  if (!bits_ || s.empty() || (c >> 24) == 0) return 0;
  const int tw = rc.right - rc.left;
  const int th = rc.bottom - rc.top;
  if (tw <= 0 || th <= 0) return 0;
  Flush();
  auto& m = Mask();
  if (!m.Ensure(tw, th)) return 0;
  for (int y = 0; y < th; ++y) std::fill_n(m.bits + y * m.w, tw, 0u);
  HGDIOBJ of = SelectObject(m.dc, FontFor(px, weight, false));
  RECT r{0, 0, tw, th};
  SIZE sz{};
  GetTextExtentPoint32W(m.dc, s.c_str(), static_cast<int>(s.size()), &sz);
  DrawTextW(m.dc, s.c_str(), static_cast<int>(s.size()), &r, fmt | DT_NOPREFIX);
  GdiFlush();
  SelectObject(m.dc, of);
  Composite(rc, m.bits, m.w, c);
  return std::min(static_cast<int>(sz.cx), tw);
}

void Canvas::Icon(const RECT& box, uint32_t cp, float px, Argb c) {
  if (!bits_ || !cp || (c >> 24) == 0) return;
  LoadFonts();
  if (Fonts().icon_face.empty()) return;
  const int size = std::max(1, static_cast<int>(std::lround(px)));
  const int cx = (box.left + box.right) / 2;
  const int cy = (box.top + box.bottom) / 2;
  RECT rc{cx - size, cy - size, cx + size, cy + size};
  Flush();
  auto& m = Mask();
  const int tw = rc.right - rc.left;
  const int th = rc.bottom - rc.top;
  if (!m.Ensure(tw, th)) return;
  for (int y = 0; y < th; ++y) std::fill_n(m.bits + y * m.w, tw, 0u);
  HGDIOBJ of = SelectObject(m.dc, FontFor(px, 400, true));
  const std::wstring s = CodepointString(cp);
  SIZE sz{};
  GetTextExtentPoint32W(m.dc, s.c_str(), static_cast<int>(s.size()), &sz);
  TEXTMETRICW tm{};
  GetTextMetricsW(m.dc, &tm);
  // Material 图标字形占满 em 方框（基线之上 size 高）：把 em 方框居中。
  const int x = (tw - sz.cx) / 2;
  const int y = (th - size) / 2 + size - tm.tmAscent;
  TextOutW(m.dc, x, y, s.c_str(), static_cast<int>(s.size()));
  GdiFlush();
  SelectObject(m.dc, of);
  Composite(rc, m.bits, m.w, c);
}

int Canvas::Measure(const std::wstring& s, float px, int weight) const {
  if (s.empty()) return 0;
  auto& m = Mask();
  if (!m.Ensure(4, 4)) return 0;
  HGDIOBJ of = SelectObject(m.dc, FontFor(px, weight, false));
  SIZE sz{};
  GetTextExtentPoint32W(m.dc, s.c_str(), static_cast<int>(s.size()), &sz);
  SelectObject(m.dc, of);
  return sz.cx;
}

int Canvas::LineHeight(float px, int weight) const {
  auto& m = Mask();
  if (!m.Ensure(4, 4)) return static_cast<int>(px * 1.45f);
  HGDIOBJ of = SelectObject(m.dc, FontFor(px, weight, false));
  TEXTMETRICW tm{};
  GetTextMetricsW(m.dc, &tm);
  SelectObject(m.dc, of);
  return tm.tmHeight;
}

void PresentLayered(HWND hwnd, const Canvas& cv, int screen_x, int screen_y) {
  if (!hwnd || !cv.dc()) return;
  POINT dst{screen_x, screen_y};
  SIZE size{cv.width(), cv.height()};
  POINT src{0, 0};
  BLENDFUNCTION bf{AC_SRC_OVER, 0, 255, AC_SRC_ALPHA};
  UpdateLayeredWindow(hwnd, nullptr, &dst, &size, cv.dc(), &src, 0, &bf, ULW_ALPHA);
}

}  // namespace kotv_chrome
