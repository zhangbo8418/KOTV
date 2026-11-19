import 'package:flutter/material.dart';

import 'kotv_android_surface.dart';

/// 原生 MPV 画面 PlatformView（仅 Android Surface/Texture）。
/// macOS/iOS 走 [KotvMpvUnderlayHole]，不再使用 AppKitView 垫片。
Widget kotvMpvSurfaceView({
  Key? key,
  required String viewType,
  bool hybrid = true,
}) {
  return kotvAndroidSurface(
    key: key,
    viewType: viewType,
    creationParams: const <String, dynamic>{},
    hybrid: hybrid,
  );
}
