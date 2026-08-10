import 'package:flutter/foundation.dart';
import 'package:fvp/fvp.dart' as fvp;

/// 注册 libmdk 为 [video_player] 实现（非 Web）。
///
/// Android 开 tunnel 以求 MediaCodec→Surface 更接近零拷贝。
void kotvRegisterFvp() {
  if (kIsWeb) return;
  fvp.registerWith(options: {
    'platforms': const ['windows', 'macos', 'linux', 'android', 'ios'],
    'tunnel': true,
    'lowLatency': 1,
  });
}
