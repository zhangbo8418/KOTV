# Linux 原生 MPV

- **实现**：[`kotv_mpv_plugin.cc`](kotv_mpv_plugin.cc) — X11：`vo=x11`+`wid`；否则 `vo=libmpv`
- **频道**：`kotv_mpv` / `kotv_mpv/events`
- **hwdec**：Dart `KotvMpvOpts.hwdecValue()` 下发
- **头文件**：`include/mpv/`
