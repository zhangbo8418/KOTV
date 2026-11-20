#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"

namespace {

constexpr wchar_t kSingleInstanceMutex[] = L"Local\\com.bobo.kotv";
constexpr wchar_t kWindowClass[] = L"FLUTTER_RUNNER_WIN32_WINDOW";
constexpr wchar_t kWindowTitle[] = L"KO影视";

void BringExistingWindowToFront() {
  HWND hwnd = ::FindWindowW(kWindowClass, kWindowTitle);
  if (hwnd == nullptr) {
    return;
  }
  if (::IsIconic(hwnd)) {
    ::ShowWindow(hwnd, SW_RESTORE);
  } else {
    ::ShowWindow(hwnd, SW_SHOW);
  }
  HWND foreground = ::GetForegroundWindow();
  DWORD foreground_thread = ::GetWindowThreadProcessId(foreground, nullptr);
  DWORD target_thread = ::GetWindowThreadProcessId(hwnd, nullptr);
  const bool attached =
      foreground_thread != 0 && target_thread != 0 &&
      foreground_thread != target_thread &&
      ::AttachThreadInput(foreground_thread, target_thread, TRUE);
  ::SetForegroundWindow(hwnd);
  ::BringWindowToTop(hwnd);
  if (attached) {
    ::AttachThreadInput(foreground_thread, target_thread, FALSE);
  }
}

// Win8+ 才有 DirectComposition；Win7 即使装了平台更新也没有。
bool IsWindows8OrGreaterLocal() {
  using RtlGetVersionFn = LONG(WINAPI*)(PRTL_OSVERSIONINFOW);
  HMODULE ntdll = ::GetModuleHandleW(L"ntdll.dll");
  if (!ntdll) return false;
  auto rtl = reinterpret_cast<RtlGetVersionFn>(
      ::GetProcAddress(ntdll, "RtlGetVersion"));
  if (!rtl) return false;
  RTL_OSVERSIONINFOW vi{};
  vi.dwOSVersionInfoSize = sizeof(vi);
  if (rtl(&vi) != 0) return false;
  // Win8 = 6.2
  return vi.dwMajorVersion > 6 ||
         (vi.dwMajorVersion == 6 && vi.dwMinorVersion >= 2);
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      wchar_t *command_line, int show_command) {
  HANDLE instance_mutex = ::CreateMutexW(nullptr, TRUE, kSingleInstanceMutex);
  if (instance_mutex != nullptr && ::GetLastError() == ERROR_ALREADY_EXISTS) {
    BringExistingWindowToFront();
    ::CloseHandle(instance_mutex);
    return EXIT_SUCCESS;
  }

  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  // DComp 补丁引擎：Win8+ 在创建引擎前打开；库存引擎上该变量为 no-op。
  // 须配合 scripts/install-flutter-windows-dcomp-engine.sh 灌入的制品。
  if (IsWindows8OrGreaterLocal()) {
    ::SetEnvironmentVariableW(L"FLUTTER_WINDOWS_DCOMP", L"1");
  }

  flutter::DartProject project(L"data");

  // DComp 洞依赖逐像素 alpha；Impeller GLES 在部分驱动上 alpha 不准会黑洞。
#if defined(FLUTTER_VERSION_MAJOR) && (FLUTTER_VERSION_MAJOR > 3 || \
    (FLUTTER_VERSION_MAJOR == 3 && FLUTTER_VERSION_MINOR >= 47))
  project.set_impeller_switch(flutter::ImpellerSwitch::Disabled);
#endif

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(kWindowTitle, origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  if (instance_mutex != nullptr) {
    ::CloseHandle(instance_mutex);
  }
  return EXIT_SUCCESS;
}
