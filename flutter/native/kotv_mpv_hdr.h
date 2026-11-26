// Windows / Linux 原生 MPV 共用：HDR 输出基线。
//
// 在 mpv_initialize 前调用。会话里再套 mpv.conf 时可覆盖（这些键勿放进 managed）。
// Darwin（Swift）无法共用本头，须在 KotvMpvCore.setupMpv 保持同一组默认。
//
// - target-colorspace-hint=auto：有能力时向系统声明片源色彩空间
//   （Windows：D3D11 / Vulkan；Linux：主要为 Wayland HDR）
// - tone-mapping / hdr-compute-peak = auto：映射与峰值检测交给 libplacebo
//
// Windows 另设 target-contrast=inf（DXGI 报高黑位发灰），勿套到 Linux。
#pragma once

#include <mpv/client.h>

namespace kotv_mpv {

inline void set_hdr_output_defaults(mpv_handle* m) {
  if (!m) return;
  mpv_set_option_string(m, "target-colorspace-hint", "auto");
  mpv_set_option_string(m, "tone-mapping", "auto");
  mpv_set_option_string(m, "hdr-compute-peak", "auto");
}

}  // namespace kotv_mpv
