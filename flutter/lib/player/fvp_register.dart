import 'package:flutter/foundation.dart';
import 'package:fvp/fvp.dart' as fvp;

import 'kotv_platform.dart';

/// 注册 libmdk 为 [video_player] 实现（非 Web）。
///
/// - Android：默认关 tunnel（Surface 未就绪时隧道模式易黑屏有声）；硬解仍走 AMediaCodec 直出。
/// - Windows：显式 D3D11 硬解列表 + 低延迟；直播 HLS/伪扩展名流依赖 mdk 探测。
void kotvRegisterFvp() {
  if (kIsWeb) return;
  final platforms = const ['windows', 'macos', 'linux', 'android', 'ios'];
  if (kotvIsAndroid()) {
    fvp.registerWith(options: {
      'platforms': platforms,
      'tunnel': false,
      'video.decoders': const ['AMediaCodec', 'FFmpeg', 'dav1d'],
    });
    return;
  }
  if (!kIsWeb && defaultTargetPlatform == TargetPlatform.windows) {
    fvp.registerWith(options: {
      'platforms': platforms,
      'video.decoders': const ['MFT:d3d=11', 'D3D11', 'DXVA', 'CUDA', 'FFmpeg', 'dav1d'],
      // 直播起播更快；nobuffer 对部分源更敏感，仍保留 1。
      'lowLatency': 1,
    });
    return;
  }
  fvp.registerWith(options: {
    'platforms': platforms,
  });
}
