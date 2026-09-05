import 'package:flutter/foundation.dart';
import 'package:fvp/fvp.dart' as fvp;

import 'kotv_platform.dart';

/// 注册 libmdk 为 [video_player] 实现（非 Web）。
///
/// 延迟到首次使用 FVP 时再注册，避免启动时加载 mdk/libffmpeg 与 libmpv 同进程冲突。
bool _kotvFvpRegistered = false;

void kotvEnsureFvpRegistered() {
  if (_kotvFvpRegistered || kIsWeb) return;
  _kotvFvpRegistered = true;
  kotvRegisterFvp();
}

/// 注册 libmdk（由 [kotvEnsureFvpRegistered] 在需要时调用，勿在 main 里无条件注册）。
///
/// [FvpPlayback] 现直接握 `package:fvp/mdk.dart` [Player] 换集复用；仍须 registerWith
/// 以注入 MDK_KEY / 全局 player 选项。解码器列表在开播时由 [kotvFvpVideoDecoders] 写入。
/// Android 仅关 tunnel（Surface 未就绪时隧道模式易黑屏有声）。
///
/// 302 跟跳交给 mdk 默认 IO（未改 `io.avio`；有效性未在多系统验证）。
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
