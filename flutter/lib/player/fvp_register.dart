import 'package:flutter/foundation.dart';
import 'package:fvp/fvp.dart' as fvp;

import 'kotv_platform.dart';

/// 注册 libmdk 为 [video_player] 实现（非 Web）。
///
/// 不绑死 `video.decoders`：H.264 / HEVC 等硬解直出交给 mdk 与驱动协商。
/// Android 仅关 tunnel（Surface 未就绪时隧道模式易黑屏有声），与编码白名单无关。
/// 直播网关 302 由 [kotvResolveFvpMediaUrl] 在开播前展开；此处加大 probesize 辅助协商。
void kotvRegisterFvp() {
  if (kIsWeb) return;
  const platforms = ['windows', 'macos', 'linux', 'android', 'ios'];
  const playerOpts = <String, String>{
    // 直播 / 伪扩展名：给足探测窗口（勿用 lowLatency 的极小 analyzeduration，易 prepare 失败）
    'avformat.probesize': '8000000',
    'avformat.analyzeduration': '8000000',
    // 点播进度条：demux 包缓存报已下载区间（默认解码队列仅 ~4s）。
    // 预读上限仍由开播后 setBufferRange + KotvBufferBudget 换算（mdk 无字节帽 API）。
    'demux.buffer.ranges': '16',
    'demux.buffer.protocols': 'http,https',
  };
  if (kotvIsAndroid()) {
    fvp.registerWith(options: {
      'platforms': platforms,
      'tunnel': false,
      'player': playerOpts,
    });
    return;
  }
  fvp.registerWith(options: {
    'platforms': platforms,
    'player': playerOpts,
  });
}
