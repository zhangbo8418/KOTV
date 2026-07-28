cmake_minimum_required(VERSION 3.14)
set(PROJECT_NAME "kotv_vlc")
project(${PROJECT_NAME} LANGUAGES CXX C)

set(PLUGIN_NAME "kotv_vlc_plugin")

add_library(${PLUGIN_NAME} SHARED
  "kotv_vlc_plugin.cpp"
  "kotv_vlc_plugin_c_api.cpp"
  "../common/vlc_shim.c"
)

apply_standard_settings(${PLUGIN_NAME})
set_target_properties(${PLUGIN_NAME} PROPERTIES CXX_VISIBILITY_PRESET hidden)
target_compile_definitions(${PLUGIN_NAME} PRIVATE FLUTTER_PLUGIN_IMPL)
target_include_directories(${PLUGIN_NAME} INTERFACE
  "${CMAKE_CURRENT_SOURCE_DIR}/include")
target_include_directories(${PLUGIN_NAME} PRIVATE
  "${CMAKE_CURRENT_SOURCE_DIR}/../common")
target_link_libraries(${PLUGIN_NAME} PRIVATE flutter flutter_wrapper_plugin)

set(kotv_vlc_bundled_libraries "" PARENT_SCOPE)
