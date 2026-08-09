#include "flutter_window.h"

#include <cstdint>
#include <optional>
#include <vector>

#include <flutter/standard_method_codec.h>
#include <iphlpapi.h>

#include "flutter/generated_plugin_registrant.h"

#pragma comment(lib, "iphlpapi.lib")

namespace {

// 用 GetIfTable（XP+）而非 GetIfTable2：后者依赖 Vista+ netioapi 宏，
// 在部分 CI/SDK 组合下 PMIB_IF_TABLE2 不会声明，导致 /WX 编译失败。
// dwInOctets 为 32 位，缓冲期差分测速足够用。
int64_t InterfaceRxBytes() {
  ULONG size = 0;
  DWORD err = GetIfTable(nullptr, &size, FALSE);
  if (err != ERROR_INSUFFICIENT_BUFFER || size == 0) {
    return -1;
  }
  std::vector<BYTE> buf(size);
  auto* table = reinterpret_cast<MIB_IFTABLE*>(buf.data());
  err = GetIfTable(table, &size, FALSE);
  if (err == ERROR_INSUFFICIENT_BUFFER) {
    buf.resize(size);
    table = reinterpret_cast<MIB_IFTABLE*>(buf.data());
    err = GetIfTable(table, &size, FALSE);
  }
  if (err != NO_ERROR) {
    return -1;
  }
  uint64_t total = 0;
  for (DWORD i = 0; i < table->dwNumEntries; ++i) {
    const MIB_IFROW& row = table->table[i];
    if (row.dwType == IF_TYPE_SOFTWARE_LOOPBACK) {
      continue;
    }
    total += row.dwInOctets;
  }
  return static_cast<int64_t>(total);
}

}  // namespace

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
  RegisterHostChannel();
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

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
          result->Success(flutter::EncodableValue(InterfaceRxBytes()));
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
