import 'package:flutter/foundation.dart';
import 'package:fvp/fvp.dart' as fvp;

/// 注册 libmdk 为 [video_player] 实现（非 Web）。
///
/// 注意：勿默认开 `tunnel`——Surface/Texture 未就绪时 MediaCodec 隧道模式
/// 会「有声黑屏」（Android 上尤为明显）。需要零拷贝时再按机型白名单开启。
void kotvRegisterFvp() {
  if (kIsWeb) return;
  fvp.registerWith(options: {
    'platforms': const ['windows', 'macos', 'linux', 'android', 'ios'],
    'tunnel': false,
  });
}
