# Windows 原生 MPV

- **实现**：[`kotv_mpv_plugin.cpp`](kotv_mpv_plugin.cpp) — `vo=gpu-next` + 子 HWND，频道 `kotv_mpv`
- **hwdec**：Dart `KotvMpvOpts.hwdecValue()` 经 create/setDecode/setOpts 下发；Win7 硬解直出为 `dxva2`
- **头文件**：`include/mpv/`
