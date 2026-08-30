cmake_minimum_required(VERSION 3.14)
project(runner LANGUAGES C CXX)

# Define the application target. To change its name, change BINARY_NAME in the
# top-level CMakeLists.txt, not the value here, or `flutter run` will no longer
# work.
#
# Any new source files that you add to the application should be added here.
set(KOTV_MPV_NATIVE "${CMAKE_SOURCE_DIR}/../native/kotv_mpv")
set(KOTV_MPV_SHIM "${CMAKE_SOURCE_DIR}/../../internal/player/embed/mpv_shim.c")

add_executable(${BINARY_NAME} WIN32
  "flutter_window.cpp"
  "kotv_iface_rx.cpp"
  "main.cpp"
  "utils.cpp"
  "win32_window.cpp"
  "${FLUTTER_MANAGED_DIR}/generated_plugin_registrant.cc"
  "${KOTV_MPV_NATIVE}/kotv_mpv_plugin_win.cpp"
  "${KOTV_MPV_NATIVE}/kotv_mpv_desktop_core.c"
  "${KOTV_MPV_NATIVE}/kotv_mpv_lib_path.cpp"
  "${KOTV_MPV_SHIM}"
  "Runner.rc"
  "runner.exe.manifest"
)

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
target_link_libraries(${BINARY_NAME} PRIVATE flutter flutter_wrapper_app)
target_link_libraries(${BINARY_NAME} PRIVATE "dwmapi.lib")
target_link_libraries(${BINARY_NAME} PRIVATE "iphlpapi.lib")
target_include_directories(${BINARY_NAME} PRIVATE "${CMAKE_SOURCE_DIR}" "${KOTV_MPV_NATIVE}")

# Run the Flutter tool portions of the build. This must not be removed.
add_dependencies(${BINARY_NAME} flutter_assemble)
