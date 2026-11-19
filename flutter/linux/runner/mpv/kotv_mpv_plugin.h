#pragma once

#include <flutter_linux/flutter_linux.h>

// Linux 原生 MPV：X11 下 vo=x11 + wid；否则 vo=libmpv。hwdec 由 Dart 下发。
void kotv_mpv_plugin_register_with_registrar(FlPluginRegistrar* registrar);
