# Windows 原生 MPV

- **实现**：[`kotv_mpv_plugin.cpp`](kotv_mpv_plugin.cpp) — `vo=gpu-next` + 子 HWND，频道 `kotv_mpv`
- **hwdec**：Dart `KotvMpvOpts.hwdecValue()` 经 create/setDecode/setOpts 下发；Win7 硬解直出为 `dxva2`
- **合成**：
  - Win8+：打包脚本灌入 DComp 补丁引擎；`main.cpp` 设 `FLUTTER_WINDOWS_DCOMP=1` 并关 Impeller；Flutter 洞 clear，UI 盖在视频上
  - Win7：库存引擎；[`kotv_win_chrome`](../kotv_win_chrome.cpp) 原生播控壳（顶底栏/更多/弹幕设置/选播放器/直播分组·EPG·设置药丸）；字幕由 mpv 画在 HWND
- **头文件**：`include/mpv/`
