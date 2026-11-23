# Linux 原生 MPV

- **实现**：[`kotv_mpv_plugin.cc`](kotv_mpv_plugin.cc) — X11：`vo=gpu-next,gpu,x11`+`wid`（Vulkan 开关时 `gpu-api=vulkan,auto`）；否则 `vo=libmpv`
- **频道**：`kotv_mpv` / `kotv_mpv/events`
- **hwdec**：Dart `KotvMpvOpts.hwdecValue()` 下发
- **头文件**：`include/mpv/`
