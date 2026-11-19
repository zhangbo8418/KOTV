#pragma once

#include <flutter/plugin_registrar_windows.h>

// Windows 原生 MPV：vo=gpu-next + 子 HWND；hwdec 由 Dart KotvMpvOpts.hwdecValue 下发
//（Win7 硬解直出为 dxva2）。
void KotvMpvPluginRegisterWithRegistrar(FlutterDesktopPluginRegistrarRef registrar);
