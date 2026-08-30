#ifndef KOTV_MPV_PLUGIN_H
#define KOTV_MPV_PLUGIN_H

namespace flutter {
class FlutterEngine;
}

void RegisterKotvMpvPlugin(flutter::FlutterEngine* engine);

#if defined(__linux__)
struct _FlView;
typedef struct _FlView FlView;
void kotv_mpv_plugin_register_linux(FlView* view);
#endif

#if defined(__APPLE__)
#include <FlutterMacOS/FlutterMacOS.h>
void kotv_mpv_plugin_register_macos(FlutterEngine* engine);
#endif

#endif
