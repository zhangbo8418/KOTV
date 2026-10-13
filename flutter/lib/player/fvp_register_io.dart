import 'package:flutter/foundation.dart';
import 'package:fvp/fvp.dart' as fvp;
import 'package:fvp/mdk.dart' as mdk;

import 'drm_opts.dart';
import 'fvp_decoders.dart';
import 'fvp_diag.dart';
import 'kotv_platform.dart';

/// 注册 libmdk 为 [video_player] 实现（非 Web）。
///
/// 延迟到首次使用 FVP 时再注册，避免启动时加载 mdk/libffmpeg 与 libmpv 同进程冲突。
bool _kotvFvpRegistered = false;

/// fvp registerWith 自带 setLogHandler（进 package logging，常被滤掉）。
/// 注册后再挂：落盘时钟 + **HTTP 跟跳/Cookie/HTML**（Win7 直播取证；只读，不解析 Location）。
bool _kotvFvpMdkClockLogHooked = false;

void _kotvHookFvpMdkClockLog() {
  if (_kotvFvpMdkClockLogHooked) return;
  _kotvFvpMdkClockLogHooked = true;
  // 必须显式开 ffmpeg http 类日志，否则 mdk 默认几乎看不到 302/Location/Cookie。
  try {
    mdk.setGlobalOption('ffmpeg.log', 'debug=http');
  } catch (_) {}
  mdk.setLogHandler((level, msg) {
    final t = msg.trim();
    if (t.isEmpty) return;
    final interesting = _kotvFvpMdkLogInteresting(t);
    final lv = level.rawValue;
    if (lv > mdk.LogLevel.warning.rawValue && !interesting) return;
    final lvName = lv <= mdk.LogLevel.error.rawValue
        ? 'error'
        : lv <= mdk.LogLevel.warning.rawValue
            ? 'warning'
            : lv <= mdk.LogLevel.info.rawValue
                ? 'info'
                : 'debug';
    KotvFvpDiag.note('mdk[$lvName] ${_kotvFvpMdkLogScrub(t)}');
  });
}

bool _kotvFvpMdkLogInteresting(String raw) {
  final s = raw.toLowerCase();
  // 时钟
  if (s.contains('avsync') ||
      s.contains('a/v') ||
      s.contains('sync') ||
      s.contains('clock') ||
      s.contains('pts') ||
      s.contains('dts') ||
      s.contains('stall') ||
      s.contains('underflow') ||
      s.contains('underrun') ||
      s.contains('audioclock') ||
      s.contains('master')) {
    return true;
  }
  // 跟跳 / Cookie / HTML / IO（Win7 直播缺的就是这类）
  return s.contains('http') ||
      s.contains('https') ||
      s.contains('avio') ||
      s.contains('redirect') ||
      s.contains('location') ||
      s.contains('cookie') ||
      s.contains('set-cookie') ||
      s.contains('302') ||
      s.contains('301') ||
      s.contains('307') ||
      s.contains('308') ||
      s.contains('403') ||
      s.contains('401') ||
      s.contains('user-agent') ||
      s.contains('referer') ||
      s.contains('playlist') ||
      s.contains('m3u8') ||
      s.contains('html') ||
      s.contains('<!doctype') ||
      s.contains('<html') ||
      s.contains('content-type') ||
      s.contains('opening') ||
      s.contains('open ') ||
      s.contains('connected') ||
      s.contains('reconnect');
}

/// 去掉 query，避免 token/签名进日志；保留 host/path 便于对跟跳。
String _kotvFvpMdkLogScrub(String raw) {
  return raw.replaceAllMapped(RegExp(r'https?://\S+'), (m) {
    var s = m.group(0)!;
    // 去掉尾部常见标点
    while (s.isNotEmpty && ',"\')]>'.contains(s[s.length - 1])) {
      s = s.substring(0, s.length - 1);
    }
    try {
      final u = Uri.parse(s);
      final path = u.path.isEmpty ? '' : u.path;
      final q = u.hasQuery ? '?…' : '';
      return '${u.scheme}://${u.host}$path$q';
    } catch (_) {
      return s;
    }
  });
}

/// 上次写进 registerWith 的签名。变了才再次注册。
String _kotvFvpSig = '';

/// 当前开播要用的 ClearKey。解码方式单独变化时保留，避免下一次 prepare 丢掉密钥。
String _kotvFvpClearKey = '';

/// 安卓是否走 Surface 解码直出（`AMediaCodec:image=0`）。由 [playerRender] 决定。
/// 注意：fvp 的 `tunnel` 选项在部分机型（ADB：feature-tunneled-playback 无对应项）
/// 会卡成约 1fps；Surface 只用 platformView + image=0，**永不启 mdk tunnel**。
bool _kotvFvpAndroidSurface = true;

/// [decodeMode] 决定 prepare 用的解码器。
/// [syncClearKey] 为 true 时用 [clearKeyHex] 覆盖已记住的密钥（空串表示这次没有密钥）。
/// [androidSurface] 为 null 时沿用上次；Surface→image=0，Texture→普通 AMediaCodec。
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
/// Android：[playerRender] Surface → platformView + `AMediaCodec:image=0`；
/// Texture → textureView + 普通 AMediaCodec。**永不设 fvp `tunnel=true`**
///（设备 ADB：tunnel 请求无对应项时 MediaCodec 出帧间隔恒约 1000ms）。
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
  // 抬高 mdk + ffmpeg http 日志（跟跳/Cookie）；Windows 另钉 d3d11.copy。
  // 不做 Dart Location 解析——只落盘取证。
  final global = <String, Object>{
    'log': 'all',
    'ffmpeg.log': 'debug=http',
  };
  if (windows) {
    // Win7 / Win10+ 共用：同设备渲染，跳过跨设备 GPU 拷贝。
    global['d3d11.copy'] = 0;
  }
  options['global'] = global;
  if (kotvIsAndroid()) {
    // 强制关 tunnel：与 Exo 的「Surface 可开隧道」不同，mdk tunnel 在本机实测不可用。
    options['tunnel'] = false;
  }
  fvp.registerWith(options: options);
  // 必须在 registerWith 之后，盖掉插件自带 logging handler。
  _kotvHookFvpMdkClockLog();
  KotvFvpDiag.note(
    'clock-register decode=$decodeMode surface=$androidSurface '
    'win7=${kotvIsWindows7()}',
  );
}
