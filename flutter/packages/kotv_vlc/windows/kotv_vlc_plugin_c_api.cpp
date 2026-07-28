#include "include/kotv_vlc/kotv_vlc_plugin_c_api.h"

#include <flutter/plugin_registrar_windows.h>

#include "kotv_vlc_plugin.h"

void KotvVlcPluginCApiRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar) {
  kotv_vlc::KotvVlcPlugin::RegisterWithRegistrar(
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar));
}
