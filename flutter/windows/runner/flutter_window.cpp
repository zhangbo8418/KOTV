#include "flutter_window.h"

#include <optional>

#include <flutter/standard_method_codec.h>
#include <windows.h>

#include "flutter/generated_plugin_registrant.h"
#include "kotv_external_player.h"
#include "kotv_iface_rx.h"
#if defined(KOTV_WIN7_CHROME)
#include "kotv_win_chrome.h"
#endif
#include "mpv/kotv_mpv_plugin.h"

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  KotvMpvPluginRegisterWithRegistrar(
      flutter_controller_->engine()->GetRegistrarForPlugin("KotvMpvPlugin"));
#if defined(KOTV_WIN7_CHROME)
  // 仅 Win7 包：进程内 GDI+ 播控壳。Win8+ 与 macOS 同为 Flutter chrome。
  KotvWinChromeRegisterWithRegistrar(
      flutter_controller_->engine()->GetRegistrarForPlugin("KotvWinChrome"));
#endif
  RegisterHostChannel();
  SetChildContent(flutter_controller_->view()->GetNativeWindow());
#if defined(KOTV_WIN7_CHROME)
  // 视频与播控是 Flutter 视图的子窗口：父窗口重绘时必须裁掉它们，否则 Win7 上每帧都会盖住播控。
  {
    HWND view = flutter_controller_->view()->GetNativeWindow();
    HWND top = GetHandle();
    const LONG_PTR clip = WS_CLIPCHILDREN | WS_CLIPSIBLINGS;
    SetWindowLongPtrW(view, GWL_STYLE, GetWindowLongPtrW(view, GWL_STYLE) | clip);
    SetWindowLongPtrW(top, GWL_STYLE, GetWindowLongPtrW(top, GWL_STYLE) | clip);
  }
#endif

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::RegisterHostChannel() {
  host_channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      flutter_controller_->engine()->messenger(), "kotv_host",
      &flutter::StandardMethodCodec::GetInstance());
  host_channel_->SetMethodCallHandler(
      [](const flutter::MethodCall<flutter::EncodableValue>& call,
         std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
        if (call.method_name() == "getInterfaceRxBytes") {
          result->Success(flutter::EncodableValue(KotvInterfaceRxBytes()));
        } else if (call.method_name() == "getMemoryInfo") {
          MEMORYSTATUSEX st;
          st.dwLength = sizeof(st);
          flutter::EncodableMap mem;
          if (GlobalMemoryStatusEx(&st)) {
            mem[flutter::EncodableValue("totalBytes")] =
                flutter::EncodableValue(static_cast<int64_t>(st.ullTotalPhys));
            mem[flutter::EncodableValue("availBytes")] =
                flutter::EncodableValue(static_cast<int64_t>(st.ullAvailPhys));
          } else {
            mem[flutter::EncodableValue("totalBytes")] = flutter::EncodableValue(0);
            mem[flutter::EncodableValue("availBytes")] = flutter::EncodableValue(0);
          }
          result->Success(flutter::EncodableValue(mem));
        } else if (call.method_name() == "hasExternalVideoApp") {
          result->Success(flutter::EncodableValue(KotvHasExternalVideoApp()));
        } else if (call.method_name() == "listExternalVideoApps") {
          result->Success(flutter::EncodableValue(KotvListExternalVideoApps()));
        } else if (call.method_name() == "openExternalVideoApp") {
          const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
          std::string id;
          std::string url;
          if (args != nullptr) {
            const auto id_it = args->find(flutter::EncodableValue("id"));
            if (id_it != args->end()) {
              if (const auto* s = std::get_if<std::string>(&id_it->second)) {
                id = *s;
              }
            }
            const auto url_it = args->find(flutter::EncodableValue("url"));
            if (url_it != args->end()) {
              if (const auto* s = std::get_if<std::string>(&url_it->second)) {
                url = *s;
              }
            }
          }
          if (id.empty() || url.empty()) {
            result->Error("args", "id/url required");
            return;
          }
          result->Success(flutter::EncodableValue(KotvOpenExternalVideoApp(id, url)));
        } else {
          result->NotImplemented();
        }
      });
}

void FlutterWindow::OnDestroy() {
  host_channel_ = nullptr;
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
