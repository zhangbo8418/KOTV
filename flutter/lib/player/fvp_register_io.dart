import 'package:flutter/foundation.dart';
import 'package:fvp/fvp.dart' as fvp;

import 'drm_opts.dart';
import 'fvp_decoders.dart';
import 'kotv_platform.dart';

/// 注册 libmdk 为 [video_player] 实现（非 Web）。
///
/// 延迟到首次使用 FVP 时再注册，避免启动时加载 mdk/libffmpeg 与 libmpv 同进程冲突。
bool _kotvFvpRegistered = false;

/// 上次写进 registerWith 的签名。变了才再次注册。
String _kotvFvpSig = '';

/// 当前开播要用的 ClearKey。解码方式单独变化时保留，避免下一次 prepare 丢掉密钥。
String _kotvFvpClearKey = '';

/// 安卓是否走 Surface（`playerRender`）：Surface→image=0 + platformView + tunnel；
/// Texture→普通 AMediaCodec、tunnel 关。
bool _kotvFvpAndroidSurface = true;

/// [decodeMode] 决定 prepare 用的解码器。
/// [syncClearKey] 为 true 时用 [clearKeyHex] 覆盖已记住的密钥（空串表示这次没有密钥）。
/// [androidSurface] 为 null 时沿用上次。
void kotvEnsureFvpRegistered({
  String decodeMode = 'auto',
  String? clearKeyHex,
  bool syncClearKey = false,
  bool? androidSurface,
}) {
  if (kIsWeb) return;
  if (syncClearKey) _kotvFvpClearKey = (clearKeyHex ?? '').trim();
  if (androidSurface != null) _kotvFvpAndroidSurface = androidSurface;
  final surface = !kotvIsAndroid() || _kotvFvpAndroidSurface;
  final sig =
      '${kotvFvpVideoDecoders(decodeMode, androidSurface: surface).join('\u0001')}|$_kotvFvpClearKey|$_kotvFvpAndroidSurface';
  if (_kotvFvpRegistered && _kotvFvpSig == sig) return;
  _kotvFvpRegistered = true;
  _kotvFvpSig = sig;
  kotvRegisterFvp(
    decodeMode: decodeMode,
    clearKeyHex: _kotvFvpClearKey,
    androidSurface: _kotvFvpAndroidSurface,
  );
}

/// 注册 libmdk（由 [kotvEnsureFvpRegistered] 调用，勿在 main 里无条件注册）。
///
/// fvp 的 [FVPControllerExtensions] 在 initialize 之前没有 player，setVideoDecoders /
/// setProperty 会被丢掉。prepare 用的解码器、ClearKey、shader_resource 只能放在
/// registerWith 的 video.decoders / player 里，插件在 create 时、prepare 之前写入。
///
/// Android：[playerRender] Surface → platformView + `AMediaCodec:image=0` + tunnel；
/// Texture → textureView + 普通 AMediaCodec，tunnel 关。
/// fvp 的 `tunnel` 是 mdk 直绑 Surface（C++ `directSurface`，拆面时先清 decoder），
/// **不是** Exo Media3 `setTunnelingEnabled` / FEATURE_TunneledPlayback。
///
/// 缓冲：player `buffer=0+0`，create patch `setBufferRange(min:0,max:0)`；开播后再写预算 max。
///
/// Windows 渲染零拷贝（含 Win7；D3D11 **图形** API，不是 Video 解码 API）：
/// 1. 插件建共享 D3D11 设备 → d3d11.device；此处 d3d11.copy=0，跳过跨设备拷贝。
/// 2. 三块 DXGI shared 纹理轮换（GetSharedHandle，Win7 起可用）。
/// 3. MFT:shader_resource / shared 仅 win8+；Win8+ 写 video.decoder=shader_resource=1
///    盖掉 create 里的 0。Win7 不写（会卡住平台线程；解码列表见 [kotvFvpVideoDecoders]）。
///
/// 302 跟跳交给 mdk 默认 IO（勿在 Dart 里预跳，CDN 签名会过期）。
/// 不设 `avformat.input`：URL 后缀常是假的（.m3u8 实为 FLV，.png 实为 TS）。
void kotvRegisterFvp({
  String decodeMode = 'auto',
  String? clearKeyHex,
  bool androidSurface = true,
}) {
  if (kIsWeb) return;
  const platforms = ['windows', 'macos', 'linux', 'android', 'ios'];
  final surface = !kotvIsAndroid() || androidSurface;
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
    // mdk 属性 buffer = setBufferRange。"0+0" = minMs=0 + maxMs=INT64_MAX。
    // create patch 再调 setBufferRange(min:0, max:0)。开播后再写带预算的 max。
    'buffer': '0+0',
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
    'video.decoders': kotvFvpVideoDecoders(decodeMode, androidSurface: surface),
    'player': playerOpts,
  };
  if (kotvIsAndroid()) {
    // Surface+image=0 须 tunnel=true，走 directSurface 安全拆面；Texture 关 tunnel。
    options['tunnel'] = androidSurface;
  } else if (windows) {
    // Win7 / Win10+ 共用：同设备渲染，跳过跨设备 GPU 拷贝。
    options['global'] = <String, Object>{
      'd3d11.copy': 0,
    };
  }
  fvp.registerWith(options: options);
}
