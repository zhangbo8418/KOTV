import 'package:flutter/foundation.dart';
import 'package:fvp/fvp.dart' as fvp;

import 'drm_opts.dart';
import 'fvp_decoders.dart';
import 'kotv_platform.dart';

/// 注册 libmdk 为 [video_player] 实现（非 Web）。
///
/// 延迟到首次使用 FVP 时再注册，避免启动时加载 mdk/libffmpeg 与 libmpv 同进程冲突。
bool _kotvFvpRegistered = false;

/// 上次写进 registerWith 的解码器列表和 ClearKey。变了才再次注册。
String _kotvFvpSig = '';

/// 当前开播要用的 ClearKey。解码方式单独变化时保留，避免下一次 prepare 丢掉密钥。
String _kotvFvpClearKey = '';

/// [decodeMode] 决定 prepare 用的解码器。
/// [syncClearKey] 为 true 时用 [clearKeyHex] 覆盖已记住的密钥（空串表示这次没有密钥）。
void kotvEnsureFvpRegistered({
  String decodeMode = 'auto',
  String? clearKeyHex,
  bool syncClearKey = false,
}) {
  if (kIsWeb) return;
  if (syncClearKey) _kotvFvpClearKey = (clearKeyHex ?? '').trim();
  final sig = '${kotvFvpVideoDecoders(decodeMode).join('\u0001')}|$_kotvFvpClearKey';
  if (_kotvFvpRegistered && _kotvFvpSig == sig) return;
  _kotvFvpRegistered = true;
  _kotvFvpSig = sig;
  kotvRegisterFvp(decodeMode: decodeMode, clearKeyHex: _kotvFvpClearKey);
}

/// 注册 libmdk（由 [kotvEnsureFvpRegistered] 调用，勿在 main 里无条件注册）。
///
/// fvp 的 [FVPControllerExtensions] 在 initialize 之前没有 player，setVideoDecoders /
/// setProperty 会被丢掉。prepare 用的解码器、ClearKey、shader_resource 只能放在
/// registerWith 的 video.decoders / player 里，插件在 create 时、prepare 之前写入。
///
/// Android 开 tunnel，画面用 SurfaceView。解码器直接写 Surface，不经 GL。
/// shader_resource 只适用于 D3D11 且 Win8 及以上，用 1 盖掉 create 里写死的 0。
/// d3d11.sync.cpu 是全局渲染选项。插件先写成 1，Windows（含 Win7）再写成 0。
/// 画面是三块纹理，renderVideo 画进 Flutter 没拿着的那块。Mac、Linux、iOS 不写这两项。
///
/// 302 跟跳交给 mdk 默认 IO（勿在 Dart 里预跳，CDN 签名会过期）。
/// 不设 `avformat.input`：URL 后缀常是假的（.m3u8 实为 FLV，.png 实为 TS）。
void kotvRegisterFvp({String decodeMode = 'auto', String? clearKeyHex}) {
  if (kIsWeb) return;
  const platforms = ['windows', 'macos', 'linux', 'android', 'ios'];
  final playerOpts = <String, String>{
    // 直播 / 伪扩展名：给足探测窗口（勿用 lowLatency 的极小 analyzeduration，易 prepare 失败）
    'avformat.probesize': '8000000',
    'avformat.analyzeduration': '8000000',
    // 伪装扩展名靠探测，不设 protocol_whitelist（否则 RTSP/RTMP/RTP 会被挡）。
    'avformat.extension_picky': '0',
    'avformat.allowed_extensions': 'ALL',
    'avformat.allowed_segment_extensions': 'ALL',
    'avio.reconnect': '1',
    'avio.reconnect_delay_max': '7',
    // 不设 demux.buffer.ranges。那是内存里的 demux 包缓存，只按段数丢弃，没有字节上限，
    // 播完仍留着；setBufferRange 限制的是另一条解码队列。预读时长由开播后的 setBufferRange 管。
  };
  final key = (clearKeyHex ?? '').trim();
  if (key.isNotEmpty) {
    playerOpts['demux.lavf.o'] = kotvLavfOWithClearKey(key);
  }
  final windows = kotvIsWindows();
  if (windows && !kotvIsWindows7()) {
    playerOpts['video.decoder'] = 'shader_resource=1';
  }
  final options = <String, dynamic>{
    'platforms': platforms,
    'video.decoders': kotvFvpVideoDecoders(decodeMode),
    'player': playerOpts,
  };
  if (kotvIsAndroid()) {
    options['tunnel'] = true;
  } else if (windows) {
    options['global'] = <String, Object>{
      'd3d11.sync.cpu': 0,
    };
  }
  fvp.registerWith(options: options);
}
