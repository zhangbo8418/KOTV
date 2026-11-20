cmake_minimum_required(VERSION 3.14)
project(runner LANGUAGES C CXX)

# Define the application target. To change its name, change BINARY_NAME in the
# top-level CMakeLists.txt, not the value here, or `flutter run` will no longer
# work.
#
# Any new source files that you add to the application should be added here.
add_executable(${BINARY_NAME} WIN32
  "flutter_window.cpp"
  "kotv_external_player.cpp"
  "kotv_iface_rx.cpp"
  "kotv_win_chrome.cpp"
  "main.cpp"
  "utils.cpp"
  "win32_window.cpp"
  "mpv/kotv_mpv_plugin.cpp"
  "${FLUTTER_MANAGED_DIR}/generated_plugin_registrant.cc"
  "Runner.rc"
  "runner.exe.manifest"
)

# kotv_mpv：vo=gpu-next + 子 HWND；头文件在 runner/mpv/include。
# 链接必须用导入库：MSVC=mpv.lib，MinGW=libmpv.dll.a。勿把 .dll 交给 link.exe（LNK1107）。
set(KOTV_MPV_WIN_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../../assets/mpv-libs/windows")
target_include_directories(${BINARY_NAME} PRIVATE
  "${CMAKE_SOURCE_DIR}"
  "${CMAKE_CURRENT_SOURCE_DIR}/mpv/include"
)
set(KOTV_MPV_LINKED FALSE)
if(EXISTS "${KOTV_MPV_WIN_DIR}/mpv.lib")
  target_link_libraries(${BINARY_NAME} PRIVATE "${KOTV_MPV_WIN_DIR}/mpv.lib")
  set(KOTV_MPV_LINKED TRUE)
elseif(EXISTS "${KOTV_MPV_WIN_DIR}/libmpv.dll.a")
  target_link_libraries(${BINARY_NAME} PRIVATE "${KOTV_MPV_WIN_DIR}/libmpv.dll.a")
  set(KOTV_MPV_LINKED TRUE)
elseif(MINGW AND EXISTS "${KOTV_MPV_WIN_DIR}/mpv-2.dll")
  # 仅 MinGW 可对 dll 做隐式链接。
  target_link_libraries(${BINARY_NAME} PRIVATE "${KOTV_MPV_WIN_DIR}/mpv-2.dll")
  set(KOTV_MPV_LINKED TRUE)
endif()
if(NOT KOTV_MPV_LINKED)
  message(FATAL_ERROR
    "kotv_mpv: missing import lib under ${KOTV_MPV_WIN_DIR} "
    "(need mpv.lib for MSVC or libmpv.dll.a for MinGW; rebuild via scripts/build-desktop-mpv-from-source.sh windows)")
endif()
target_link_libraries(${BINARY_NAME} PRIVATE "comctl32.lib")
target_compile_definitions(${BINARY_NAME} PRIVATE "KOTV_NATIVE_MPV=1")

# Apply the standard set of build settings. This can be removed for applications
# that need different build settings.
apply_standard_settings(${BINARY_NAME})

# Add preprocessor definitions for the build version.
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION=\"${FLUTTER_VERSION}\"")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_MAJOR=${FLUTTER_VERSION_MAJOR}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_MINOR=${FLUTTER_VERSION_MINOR}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_PATCH=${FLUTTER_VERSION_PATCH}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_BUILD=${FLUTTER_VERSION_BUILD}")

# Disable Windows macros that collide with C++ standard library functions.
target_compile_definitions(${BINARY_NAME} PRIVATE "NOMINMAX")

# 最低目标 Win7，保证 GetIfTable2 / MIB_IF_TABLE2 等 Vista+ API 在头文件中可见。
target_compile_definitions(${BINARY_NAME} PRIVATE
  "WINVER=0x0601"
  "_WIN32_WINNT=0x0601"
  "NTDDI_VERSION=0x06010000"
  "_CRT_SECURE_NO_WARNINGS"
  "_CRT_NONSTDC_NO_DEPRECATE"
)

# Add dependency libraries and include directories. Add any application-specific
# dependencies here.
# kotv_mpv_plugin 使用 PluginRegistrar*，须链 flutter_wrapper_plugin（否则 LNK2019）。
target_link_libraries(${BINARY_NAME} PRIVATE flutter flutter_wrapper_app flutter_wrapper_plugin)
target_link_libraries(${BINARY_NAME} PRIVATE "dwmapi.lib")
target_link_libraries(${BINARY_NAME} PRIVATE "iphlpapi.lib")
# 外部播放器：关联枚举 + HICON→PNG（WIC，Win7+）。
target_link_libraries(${BINARY_NAME} PRIVATE
  "shell32.lib"
  "ole32.lib"
  "gdi32.lib"
  "windowscodecs.lib"
)
target_include_directories(${BINARY_NAME} PRIVATE "${CMAKE_SOURCE_DIR}")

# Run the Flutter tool portions of the build. This must not be removed.
add_dependencies(${BINARY_NAME} flutter_assemble)
