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
///
/// Windows 渲染零拷贝（含 Win7；D3D11 **图形** API，不是 Video 解码 API）：
/// 1. 插件建共享 D3D11 设备 → d3d11.device；此处 d3d11.copy=0，跳过跨设备拷贝。
/// 2. 三块 DXGI shared 纹理轮换（GetSharedHandle，Win7 起可用）。
/// 3. MFT:shader_resource / shared 仅 win8+；Win8+ 写 video.decoder=shader_resource=1
///    盖掉 create 里的 0。Win7 不写（会卡住平台线程；解码列表见 [kotvFvpVideoDecoders]）。
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
    // mdk 属性 buffer = setBufferRange：值形如 "minMs" / "minMs+maxMs" / "minMs+maxMs-"。
    // "0" = minMs=0（decode ASAP）。默认 minMs=1000 欠载时约 1fps。开播后再写 max。
    // 不设 demux.buffer.ranges（无字节上限，播完仍占内存）。
    'buffer': '0',
  };
  final key = (clearKeyHex ?? '').trim();
  if (key.isNotEmpty) {
    playerOpts['demux.lavf.o'] = kotvLavfOWithClearKey(key);
  }
  final windows = kotvIsWindows();
  // MFT 的 shader_resource 仅 win8+；全局写 1 会作用到所有解码器。
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
    // Win7 / Win10+ 共用：同设备渲染，跳过跨设备 GPU 拷贝。
    options['global'] = <String, Object>{
      'd3d11.copy': 0,
    };
  }
  fvp.registerWith(options: options);
}
