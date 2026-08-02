# KOTV 本地 fork

基于 `kanata996/fijkplayer@33e41d14`。

改动：去掉 `FijkPlugin.onAttachedToEngine` 里创建 dummy `FijkPlayer` 并 `setupSurface()` 的 warmup。
该调用会在 `GeneratedPluginRegistrant` 阶段触发 `FlutterJNI.registerTexture`，在部分红米/HyperOS 机型上导致首启 FATAL（`platform_view_android.cc Check failed: false`）。

真正开播时仍会按需创建 SurfaceTexture。
