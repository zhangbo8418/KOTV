import 'dart:math' show max;

import 'package:flutter/foundation.dart';

import 'buffer_budget.dart';
import 'kotv_platform.dart';

/// 原生 MPV 选项：解码 / gpu-next / conf（对齐 TV mpvplayer）。
///
/// ## 平台能力（目标）
/// | 选项 | Android | 桌面 |
/// |------|---------|------|
/// | hwdec | mediacodec / auto-safe | d3d11va / dxva2 / videotoolbox |
/// | mpv.conf | setProperty | 同上 |
/// | gpu-next | vo=gpu-next（Surface） | vo=libmpv + gpu-api=vulkan（预编译 libmpv 需含 Vulkan） |
/// | AV3A | libmvcodec/libarcdav3a（webhtv） | 源码：FongMi FFmpeg+avs3a（CI: KOTV_BUILD_MPV_AV3A=1） |
class KotvMpvOpts {
  const KotvMpvOpts({
    this.decodeMode = 'auto',
    this.gpuNext = false,
    this.vulkan = false,
    this.conf = '',
  });

  final String decodeMode;
  final bool gpuNext;
  final bool vulkan;
  final String conf;

  factory KotvMpvOpts.fromSettings(Map<String, dynamic> settings, {String? decodeMode}) {
    final decode = (decodeMode ?? '${settings['playerDecode'] ?? 'auto'}').trim();
    var gpuNext = '${settings['mpvGpuNext'] ?? ''}'.toLowerCase() == 'true';
    var vulkan = '${settings['mpvVulkan'] ?? ''}'.toLowerCase() == 'true';
    // Win7：Vulkan/gpu-next 易在 libmpv 初始化时触发 talloc canary 断言。
    if (kotvIsWindows7()) {
      gpuNext = false;
      vulkan = false;
    }
    return KotvMpvOpts(
      decodeMode: decode.isEmpty ? 'auto' : decode,
      gpuNext: gpuNext,
      vulkan: vulkan,
      conf: '${settings['mpvConf'] ?? ''}',
    );
  }

  KotvMpvOpts copyWith({
    String? decodeMode,
    bool? gpuNext,
    bool? vulkan,
    String? conf,
  }) {
    return KotvMpvOpts(
      decodeMode: decodeMode ?? this.decodeMode,
      gpuNext: gpuNext ?? this.gpuNext,
      vulkan: vulkan ?? this.vulkan,
      conf: conf ?? this.conf,
    );
  }

  bool get soft => decodeMode == 'soft' || decodeMode == 'software' || decodeMode == 'sw';

  bool get hard =>
      decodeMode == 'hard' || decodeMode == 'hardware' || decodeMode == 'hw';

  /// 供原生 setProperty 使用的 hwdec 值。
  ///
  /// Android：auto → `auto-safe`（RK3399 等盒在原生层改 mediacodec 直出 Surface）；hard → `mediacodec`；soft → `no`。
  String hwdecValue() {
    if (soft) return 'no';
    if (kotvIsAndroid()) {
      if (hard) return 'mediacodec';
      return 'auto-safe';
    }
    if (hard) {
      if (!kIsWeb && defaultTargetPlatform == TargetPlatform.windows) {
        return kotvIsWindows7() ? 'dxva2' : 'd3d11va';
      }
      if (!kIsWeb &&
          (defaultTargetPlatform == TargetPlatform.macOS ||
              defaultTargetPlatform == TargetPlatform.iOS)) {
        return 'videotoolbox';
      }
    }
    return 'auto';
  }

  /// 交给原生通道的属性表（P1/P2 open / setOpts）。
  ///
  /// [live]=true 时不写点播 demuxer 预读（对齐 TV 直播默认缓冲）。
  Map<String, String> propertyMap({bool live = false}) {
    final out = <String, String>{
      'hwdec': hwdecValue(),
    };
    if (gpuNext) {
      out['vo'] = 'gpu-next';
    }
    // 桌面 Texture 软渲由原生固定 vo=libmpv；Win7 禁止强制 vulkan。
    if (vulkan && !kotvIsAndroid() && !kotvIsWindows7()) {
      out['gpu-api'] = 'vulkan';
    }
    if (!live) {
      if (kotvIsAndroid()) {
        out['cache'] = 'yes';
        out['cache-on-disk'] = 'no';
        out['demuxer-max-bytes'] = '48MiB';
        out['demuxer-max-back-bytes'] = '8MiB';
        out['demuxer-readahead-secs'] = '20';
        out['cache-secs'] = '30';
        out['framedrop'] = 'vo';
      } else {
        final budget = KotvBufferBudget.bytes();
        final forward = KotvBufferBudget.mpvMiB(budget);
        final back = KotvBufferBudget.mpvMiB(max(16 * 1024 * 1024, budget ~/ 8));
        out['cache'] = 'yes';
        out['cache-on-disk'] = 'no';
        out['demuxer-max-bytes'] = forward;
        out['demuxer-max-back-bytes'] = back;
        out['demuxer-readahead-secs'] = '1000000';
        out['cache-secs'] = '1000000';
        out['framedrop'] = 'vo';
      }
    }
    for (final e in parseConfLines(conf)) {
      out[e.$1] = e.$2;
    }
    return out;
  }

  /// 解析 mpv.conf 风格：`key=value` / `key value`；忽略空行与 `#` 注释。
  static List<(String, String)> parseConfLines(String text) {
    final out = <(String, String)>[];
    for (final raw in text.split(RegExp(r'[\r\n]+'))) {
      var line = raw.trim();
      if (line.isEmpty || line.startsWith('#')) continue;
      final hash = line.indexOf('#');
      if (hash > 0) line = line.substring(0, hash).trim();
      if (line.isEmpty) continue;
      String key;
      String value;
      final eq = line.indexOf('=');
      if (eq > 0) {
        key = line.substring(0, eq).trim();
        value = line.substring(eq + 1).trim();
      } else {
        final m = RegExp(r'\s+').firstMatch(line);
        if (m == null || m.start <= 0) continue;
        key = line.substring(0, m.start).trim();
        value = line.substring(m.end).trim();
      }
      if (key.isEmpty) continue;
      // 跳过会破坏原生 Surface 绑定的选项（由引擎自己设 vo/wid）
      if (key == 'vo' || key == 'wid' || key == 'android-surface-size') continue;
      out.add((key, value.isEmpty ? 'yes' : value));
    }
    return out;
  }
}
