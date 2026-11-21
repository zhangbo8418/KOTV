#pragma once

#include <flutter/encodable_value.h>
#include <flutter/plugin_registrar_windows.h>

#include <functional>
#include <memory>
#include <string>

#include "win7_chrome_shell.h"

// Win7：MethodChannel 薄适配 → 进程内 Win7ChromeShell（GDI+）。
// Win8+ 不编本文件。
class KotvWinChrome {
 public:
  using EncodableMap = flutter::EncodableMap;
  using EncodableValue = flutter::EncodableValue;
  using EventFn = std::function<void(EncodableMap)>;

  explicit KotvWinChrome(flutter::PluginRegistrarWindows* registrar);
  ~KotvWinChrome();

  void SetEventSink(EventFn fn);
  void HandleMethod(const std::string& method, const EncodableMap* args,
                    std::function<void(EncodableValue)> success,
                    std::function<void(const std::string&, const std::string&)> error);

 private:
  HWND FlutterHwnd() const;
  Win7ChromeShell::ChromeMap ToChromeMap(const EncodableMap& src) const;
  EncodableMap FromChromeMap(const Win7ChromeShell::ChromeMap& src) const;

  flutter::PluginRegistrarWindows* registrar_;
  EventFn event_fn_;
  Win7ChromeShell shell_;
};

void KotvWinChromeRegisterWithRegistrar(FlutterDesktopPluginRegistrarRef registrar);
