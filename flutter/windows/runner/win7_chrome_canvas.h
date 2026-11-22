#ifndef RUNNER_WIN7_CHROME_CANVAS_H_
#define RUNNER_WIN7_CHROME_CANVAS_H_

#include <windows.h>

#include <cstdint>
#include <memory>
#include <string>

namespace Gdiplus {
class Bitmap;
class Graphics;
}  // namespace Gdiplus

namespace kotv_chrome {

using Argb = uint32_t;

constexpr Argb WithOpacity(Argb c, double o) {
  const double a = ((c >> 24) & 0xFF) * (o < 0 ? 0 : (o > 1 ? 1 : o));
  return (static_cast<Argb>(a + 0.5) << 24) | (c & 0x00FFFFFF);
}

namespace icon {
constexpr uint32_t kPlay = 0xe4cb;
constexpr uint32_t kPause = 0xe47c;
constexpr uint32_t kPlayRounded = 0xf00a0;
constexpr uint32_t kPauseRounded = 0xf0056;
constexpr uint32_t kStop = 0xe606;
constexpr uint32_t kSkipPrev = 0xe5be;
constexpr uint32_t kSkipNext = 0xe5bd;
constexpr uint32_t kFastForward = 0xe258;
constexpr uint32_t kFastForwardRounded = 0xf734;
constexpr uint32_t kFastRewindRounded = 0xf735;
constexpr uint32_t kReplay = 0xe523;
constexpr uint32_t kAspect = 0xe0a3;
constexpr uint32_t kMemory = 0xe3db;
constexpr uint32_t kFlashOn = 0xe293;
constexpr uint32_t kFlashOff = 0xe292;
constexpr uint32_t kClosedCaption = 0xe16c;
constexpr uint32_t kAlbumOutlined = 0xee67;
constexpr uint32_t kAudiotrack = 0xe0b6;
constexpr uint32_t kVideocamOutlined = 0xf48c;
constexpr uint32_t kDevices = 0xe1cb;
constexpr uint32_t kCast = 0xe144;
constexpr uint32_t kPip = 0xe4c2;
constexpr uint32_t kCloseFullscreen = 0xe16b;
constexpr uint32_t kFullscreen = 0xe2cb;
constexpr uint32_t kFullscreenExit = 0xe2cc;
constexpr uint32_t kVolumeMute = 0xf0298;
constexpr uint32_t kVolumeDown = 0xf0297;
constexpr uint32_t kVolumeUp = 0xf029a;
constexpr uint32_t kBrightness = 0xf5e6;
constexpr uint32_t kClose = 0xe16a;
constexpr uint32_t kChevronRight = 0xe15f;
constexpr uint32_t kCheck = 0xe156;
}  // namespace icon

// Material 图标名（Dart 侧传字符串）→ 码位；未知返回 0。
uint32_t IconByName(const std::string& name);

// 32bpp 预乘 ARGB 画布：形状走 GDI+，文字与 Material 图标走 GDI 灰度遮罩后按 alpha 合成，
// 结果交给 UpdateLayeredWindow（Win7 顶层 popup 支持逐像素 alpha）。
class Canvas {
 public:
  Canvas();
  ~Canvas();
  Canvas(const Canvas&) = delete;
  Canvas& operator=(const Canvas&) = delete;

  bool Begin(int w, int h);
  void End();
  HDC dc() const { return dc_; }
  int width() const { return w_; }
  int height() const { return h_; }

  void SetClip(const RECT& rc);
  void ClearClip();
  // End() 之后调用：keep 以外的像素清成全透明（分层窗透明像素不接收鼠标）。
  void ClearOutside(const RECT& keep);

  void Fill(const RECT& rc, Argb c);
  void RoundRect(const RECT& rc, float radius, Argb fill, Argb border = 0, float border_w = 0);
  void Circle(float cx, float cy, float r, Argb fill);
  void Line(float x0, float y0, float x1, float y1, float w, Argb c);
  void VGradient(const RECT& rc, Argb top, Argb bottom);
  // 圆弧描边（角度单位度，0° 指向 3 点钟，顺时针为正；平头）。
  void Arc(float cx, float cy, float r, float start_deg, float sweep_deg, float w, Argb c);
  // 按 BoxFit.contain 画进 rc，并裁成圆角 radius；未缓存返回 false。
  bool Image(const RECT& rc, const std::string& key, float radius);

  // 图片缓存（Dart 解码后送来的非预乘 RGBA）。
  static void PutImage(const std::string& key, int w, int h, const uint8_t* rgba, size_t len);
  static bool HasImage(const std::string& key);

  // fmt：DT_LEFT/DT_CENTER/DT_RIGHT | DT_VCENTER | DT_SINGLELINE 等。返回绘制宽度。
  int Text(const RECT& rc, const std::wstring& s, Argb c, float px, int weight, UINT fmt);
  void Icon(const RECT& box, uint32_t cp, float px, Argb c);
  int Measure(const std::wstring& s, float px, int weight) const;
  int LineHeight(float px, int weight) const;

  static void LoadFonts();

 private:
  void Flush();
  void Composite(const RECT& dst, const uint32_t* mask, int mask_stride, Argb c);

  HDC dc_ = nullptr;
  HBITMAP bmp_ = nullptr;
  HGDIOBJ old_ = nullptr;
  uint32_t* bits_ = nullptr;
  int w_ = 0;
  int h_ = 0;
  int cap_w_ = 0;
  int cap_h_ = 0;
  RECT clip_{};
  bool has_clip_ = false;
  std::unique_ptr<Gdiplus::Bitmap> gbmp_;
  std::unique_ptr<Gdiplus::Graphics> g_;
};

// 把 popup 内容按屏幕坐标贴到分层窗。
void PresentLayered(HWND hwnd, const Canvas& cv, int screen_x, int screen_y);

}  // namespace kotv_chrome

#endif  // RUNNER_WIN7_CHROME_CANVAS_H_
