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
/// [FvpPlayback] 经 video_player + fvp 插件起播；registerWith 注入 MDK_KEY /
/// 全局 player 选项。解码器列表在开播时由 [kotvFvpVideoDecoders] 写入。
/// Android 仅关 tunnel（Surface 未就绪时隧道模式易黑屏有声）。
///
/// 302 跟跳交给 mdk 默认 IO（勿在 Dart 里预跳，CDN 签名会过期）。
/// 不设 `avformat.input`：URL 后缀常是假的（.m3u8 实为 FLV，.png 实为 TS）。
void kotvRegisterFvp() {
  if (kIsWeb) return;
  const platforms = ['windows', 'macos', 'linux', 'android', 'ios'];
  const playerOpts = <String, String>{
    // 直播 / 伪扩展名：给足探测窗口（勿用 lowLatency 的极小 analyzeduration，易 prepare 失败）
    'avformat.probesize': '8000000',
    'avformat.analyzeduration': '8000000',
    // 与 MPV 一样：伪装扩展名靠探测，不设 protocol_whitelist（否则 RTSP/RTMP/RTP 会被挡）。
    'avformat.extension_picky': '0',
    'avformat.allowed_extensions': 'ALL',
    'avformat.allowed_segment_extensions': 'ALL',
    'avio.reconnect': '1',
    'avio.reconnect_delay_max': '7',
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
    // 覆盖插件默认 d3d11.sync.cpu=1：每帧 GPU→CPU 同步会把 Texture 卡到个位数 FPS。
    'global': <String, Object>{
      'd3d11.sync.cpu': 0,
    },
    // 插件 create 时写死 shader_resource=0，会关掉 D3D11 0-copy；此处覆盖回 1。
    // Texture 尺寸交给视频帧（不设 maxWidth/maxHeight）。
    'player': <String, String>{
      ...playerOpts,
      'video.decoder': 'shader_resource=1',
    },
  });
}
