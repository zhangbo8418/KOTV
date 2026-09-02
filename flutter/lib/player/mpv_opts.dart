import 'dart:math' show max;

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'buffer_budget.dart';
import 'kotv_platform.dart';

/// MPV 选项：Android 走原生插件；桌面/Windows/macOS 走 media_kit + 自带 libmpv。
///
/// 自带 libmpv 由 scripts 编译（Vulkan 硬解、AV3A 等）；Flutter 侧不挂 wid/Surface。
/// FVP 为独立内置播放器，与 MPV 并列可选。
///
/// ## 平台能力
/// | 选项 | Android 原生 | 桌面 media_kit |
/// |------|-------------|----------------|
/// | hwdec | mediacodec / auto-safe | Win7: dxva2/auto-safe；Win8+: d3d11va/auto |
/// | gpu-next | vo=gpu-next（Surface） | ❌（Texture/libmpv） |
/// | gpu-api / Vulkan | 原生 Surface | setProperty（含 Win7） |
/// | AV3A | libmvcodec | 自带 FFmpeg+avs3a |
class KotvMpvOpts {
  const KotvMpvOpts({
    this.decodeMode = 'auto',
    this.gpuNext = false,
    this.vulkan = false,
    this.gpuApi = 'auto',
    this.conf = '',
  });

  final String decodeMode;
  final bool gpuNext;
  final bool vulkan;
  /// Windows：`auto` / `d3d11` / `opengl` / `vulkan`。
  final String gpuApi;
  final String conf;

  factory KotvMpvOpts.fromSettings(Map<String, dynamic> settings, {String? decodeMode}) {
    final decode = (decodeMode ?? '${settings['playerDecode'] ?? 'auto'}').trim();
    // Android 原生：gpu-next 仅 Surface 路径。
    var gpuNext = '${settings['mpvGpuNext'] ?? ''}'.toLowerCase() == 'true';
    if (!kotvIsAndroid()) gpuNext = false;
    var vulkan = '${settings['mpvVulkan'] ?? ''}'.toLowerCase() == 'true';
    var gpuApi = '${settings['mpvGpuApi'] ?? 'auto'}'.trim().toLowerCase();
    if (gpuApi.isEmpty) gpuApi = 'auto';
    // iOS Texture 软渲勿开 Vulkan。
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS) {
      gpuNext = false;
      vulkan = false;
      if (gpuApi == 'vulkan') gpuApi = 'auto';
    }
    if (gpuApi == 'vulkan') vulkan = true;
    if (vulkan && gpuApi == 'auto') gpuApi = 'vulkan';
    return KotvMpvOpts(
      decodeMode: decode.isEmpty ? 'auto' : decode,
      gpuNext: gpuNext,
      vulkan: vulkan,
      gpuApi: gpuApi,
      conf: '${settings['mpvConf'] ?? ''}',
    );
  }

  KotvMpvOpts copyWith({
    String? decodeMode,
    bool? gpuNext,
    bool? vulkan,
    String? gpuApi,
    String? conf,
  }) {
    return KotvMpvOpts(
      decodeMode: decodeMode ?? this.decodeMode,
      gpuNext: gpuNext ?? this.gpuNext,
      vulkan: vulkan ?? this.vulkan,
      gpuApi: gpuApi ?? this.gpuApi,
      conf: conf ?? this.conf,
    );
  }

  bool get soft => decodeMode == 'soft' || decodeMode == 'software' || decodeMode == 'sw';

  bool get hard =>
      decodeMode == 'hard' || decodeMode == 'hardware' || decodeMode == 'hw';

  /// 供 setProperty / VideoController 使用的 hwdec 值。
  ///
  /// Windows Win7：硬解走 dxva2（D3D11 Video 解码 API 为 Win8+；与 gpu-api Vulkan 无关）。
  /// Windows Win8+ 硬解：d3d11va。自动模式 Win7 用 auto-safe，避免 mpv 误选 d3d11va。
  String hwdecValue() {
    if (soft) return 'no';
    if (kotvIsAndroid()) {
      if (hard) return 'mediacodec';
      return 'auto-safe';
    }
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.windows) {
      if (kotvIsWindows7()) {
        if (hard) return 'dxva2';
        return 'auto-safe';
      }
      if (hard) return 'd3d11va';
    }
    if (hard) {
      if (!kIsWeb &&
          (defaultTargetPlatform == TargetPlatform.macOS ||
              defaultTargetPlatform == TargetPlatform.iOS)) {
        return 'videotoolbox';
      }
    }
    return 'auto';
  }

  /// Android 可切 gpu/gpu-next；桌面 media_kit 必须 libmpv（Flutter Texture）。
  VideoControllerConfiguration videoControllerConfiguration() {
    final hw = hwdecValue();
    if (kotvIsAndroid()) {
      return VideoControllerConfiguration(
        vo: gpuNext ? 'gpu-next' : 'gpu',
        hwdec: hw,
        enableHardwareAcceleration: !soft,
      );
    }
    return VideoControllerConfiguration(
      hwdec: hw,
      enableHardwareAcceleration: !soft,
    );
  }

  /// 在 VideoController 已附着之后调用：缓冲预算 + conf（media_kit 路径）。
  Future<void> applyAfterAttach(Player player, {bool live = false}) async {
    try {
      final platform = player.platform;
      if (platform == null) return;
      Future<void> set(String k, String v) async {
        await (platform as dynamic).setProperty(k, v);
      }

      try {
        await set('hwdec', hwdecValue());
      } catch (_) {}

      // 桌面 media_kit：gpu-api 走 bundled libmpv（Vulkan 等）。
      if (!kotvIsAndroid()) {
        try {
          if (gpuApi != 'auto') {
            if (gpuApi == 'd3d11' ||
                gpuApi == 'opengl' ||
                gpuApi == 'vulkan' ||
                gpuApi == 'metal') {
              await set('gpu-api', gpuApi);
            }
          } else if (vulkan) {
            await set('gpu-api', 'vulkan');
          }
        } catch (_) {}
      }

      if (!live) {
        try {
          await KotvBufferBudget.warm(force: true);
          final budget = KotvBufferBudget.bytes();
          final forward = KotvBufferBudget.mpvMiB(budget);
          final back = KotvBufferBudget.mpvMiB(max(16 * 1024 * 1024, budget ~/ 8));
          await set('cache', 'yes');
          await set('cache-on-disk', 'no');
          await set('demuxer-max-bytes', forward);
          await set('demuxer-max-back-bytes', back);
          await set('demuxer-readahead-secs', '120');
          await set('cache-secs', '90');
          await set('framedrop', 'vo');
        } catch (_) {}
      }

      for (final e in parseConfLines(conf)) {
        await set(e.$1, e.$2);
      }
    } catch (_) {}
  }

  /// 交给原生通道的属性表（P1/P2 open / setOpts）。
  ///
  /// [live]=true 时不写点播 demuxer 预读（对齐 TV 直播默认缓冲）。
  Map<String, String> propertyMap({bool live = false}) {
    final out = <String, String>{
      'hwdec': hwdecValue(),
    };
    if (gpuNext && kotvIsAndroid()) {
      out['vo'] = 'gpu-next';
    }
    // Windows / macOS：gpu-api 供 Android 原生 Surface 与桌面 media_kit 共用。
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.windows) {
      if (gpuApi == 'd3d11' || gpuApi == 'opengl' || gpuApi == 'vulkan') {
        out['gpu-api'] = gpuApi;
      } else if (vulkan) {
        out['gpu-api'] = 'vulkan';
      }
    } else if (!kIsWeb && defaultTargetPlatform == TargetPlatform.macOS) {
      if (gpuApi == 'opengl' || gpuApi == 'vulkan' || gpuApi == 'metal') {
        out['gpu-api'] = gpuApi;
      } else if (vulkan) {
        out['gpu-api'] = 'vulkan';
      }
    } else if (vulkan && kotvIsAndroid()) {
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
        out['demuxer-readahead-secs'] = '120';
        out['cache-secs'] = '90';
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
