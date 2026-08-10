import 'package:flutter/foundation.dart';
import 'package:fvp/fvp.dart' as fvp;

import 'kotv_platform.dart';

/// 注册 libmdk 为 [video_player] 实现（非 Web）。
///
/// 不绑死 `video.decoders`：H.264 / HEVC 等硬解直出交给 mdk 与驱动协商。
/// Android 仅关 tunnel（Surface 未就绪时隧道模式易黑屏有声），与编码白名单无关。
void kotvRegisterFvp() {
  if (kIsWeb) return;
  const platforms = ['windows', 'macos', 'linux', 'android', 'ios'];
  if (kotvIsAndroid()) {
    fvp.registerWith(options: {
      'platforms': platforms,
      'tunnel': false,
    });
    return;
  }
  fvp.registerWith(options: {
    'platforms': platforms,
  });
}
