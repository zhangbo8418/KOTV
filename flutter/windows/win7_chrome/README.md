# Win7 WPF 播控遮罩（独立于 Win8+）

**仅 Win7。** Win8+ 走 DComp 补丁引擎，Flutter 直接盖在视频上，不启本进程、不打本产物。

运行时依赖：**.NET Framework 4.8**（Win7 SP1 可装官方运行时）。

## 架构

```
Flutter 主窗
 ├─ mpv 子 HWND（画面）
 └─ kotv_win7_chrome.exe（本目录）
      WPF AllowsTransparency 置顶遮罩：播控 / 选集 / 弹层 / 弹幕
```

- **不** `SetParent` 嵌 Flutter
- **不** `SetWinEventHook` 贴外置播放器（内置 mpv 由 Dart `update` 给 anchor/surface 矩形）
- C++ `kotv_win_chrome.cpp` 只做 MethodChannel ↔ 本进程 stdin/stdout JSON（无 GDI 绘制）

## 构建

```bash
# 仓库根目录；或由 package-flutter-windows.sh 在 KOTV_WIN7=1 时自动调用
./scripts/build-win7-chrome.sh
```

产物 `bin/Release/kotv_win7_chrome.exe` + `Newtonsoft.Json.dll` 拷入 Flutter Release 目录，与 `kotv.exe` 同级。
