import 'package:flutter/foundation.dart';
import 'package:fvp/fvp.dart' as fvp;

import 'kotv_platform.dart';

/// 注册 libmdk 为 [video_player] 实现（非 Web）。
///
/// 此处**不**绑死 `video.decoders`：开播时由 [FvpPlayback.setDecodeMode] /
/// [kotvFvpVideoDecoders] 按「自动 / 硬解 / 软解」写入。
/// 自动 = 硬解优先 + 软解回退（mdk 协商）；硬/软解才锁死列表。
/// Android 仅关 tunnel（Surface 未就绪时隧道模式易黑屏有声）。
///
/// Windows 直播 302：mdk 默认 **custom MediaIO**（`io.avio=0`）对
/// `https → http` 空体跳转不可靠；切 FFmpeg 原生 avio，并放宽
/// `protocol_whitelist`（含 http/tcp），由播放器自己跟跳，勿在 Flutter 预展开。
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
    // https 网关 302 到 http CDN 时，嵌套协议须在白名单（否则跟跳失败）
    'avio.protocol_whitelist':
        'file,ftp,rtmp,http,https,tls,rtp,tcp,udp,crypto,httpproxy,data,concatf,concat,subfile',
  };
  const globalOpts = <String, Object>{
    // 走 FFmpeg 原生 avio（同 ffprobe/MPV），可靠跟 302；默认 custom MediaIO 在 Win 上易断
    'io.avio': 1,
  };
  if (kotvIsAndroid()) {
    fvp.registerWith(options: {
      'platforms': platforms,
      'tunnel': false,
      'global': globalOpts,
      'player': playerOpts,
    });
    return;
  }
  fvp.registerWith(options: {
    'platforms': platforms,
    'global': globalOpts,
    'player': playerOpts,
  });
}
