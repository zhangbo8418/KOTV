#pragma once

#include <flutter/encodable_value.h>
#include <flutter/plugin_registrar_windows.h>

#include <functional>
#include <memory>
#include <string>
#include <unordered_map>
#include <vector>
#include <windows.h>

// Win7 专用：MethodChannel ↔ kotv_win7_chrome.exe（WPF 透明遮罩）。
// Win8+ DComp 不启本通道（Dart kotvUsesWindowsNativeChrome() 已闸）。
// 与 Win8+ 路线完全隔离：无 GDI 子窗、无 Texture、无 DComp 依赖。
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

  // 供读线程入口调用
  void ReaderLoop();

 private:
  static constexpr UINT kWmChromeEvent = WM_APP + 0x6B07;

  HWND FlutterHwnd() const;
  bool EnsureProcess();
  void StopProcess();
  bool CallRemote(const std::string& method, const EncodableMap* args, EncodableValue* out,
                  std::string* err);
  void HandleRemoteLine(const std::string& line);
  void Emit(EncodableMap map);
  void FlushEventsOnPlatformThread();
  int64_t NextId();
  static LRESULT CALLBACK HostWndSubclass(HWND, UINT, WPARAM, LPARAM, UINT_PTR, DWORD_PTR);
  void EnsureSubclass();

  flutter::PluginRegistrarWindows* registrar_;
  EventFn event_fn_;

  HANDLE proc_ = nullptr;
  HANDLE stdin_wr_ = nullptr;
  HANDLE stdout_rd_ = nullptr;
  HANDLE reader_thread_ = nullptr;
  HANDLE ready_event_ = nullptr;
  CRITICAL_SECTION io_lock_;
  volatile LONG alive_ = 0;
  volatile LONG next_id_ = 1;
  bool subclassed_ = false;
  UINT_PTR subclass_id_ = 1;

  struct Pending {
    HANDLE event = nullptr;
    bool ok = false;
    std::string error;
    EncodableValue result;
  };
  std::unordered_map<int64_t, Pending*> pending_;
  std::vector<EncodableMap> event_queue_;
};

void KotvWinChromeRegisterWithRegistrar(FlutterDesktopPluginRegistrarRef registrar);
