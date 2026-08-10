import 'dart:math' show max;

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'buffer_budget.dart';
import 'kotv_platform.dart';

/// MPV / media_kit 选项：解码 / gpu-next / conf。
///
/// ## 平台能力
/// | 选项 | Android | 桌面 (PC) |
/// |------|---------|-----------|
/// | hwdec | ✅ mediacodec 直出 / auto | ✅ d3d11va/auto 直出（Win 排除 hevc 防卡死） |
/// | mpv.conf | ✅ 事后 setProperty | ✅ 同上 |
/// | gpu-next | ✅ vo=gpu-next | ❌ Flutter Texture 必须 vo=libmpv |
class KotvMpvOpts {
  const KotvMpvOpts({
    this.decodeMode = 'auto',
    this.gpuNext = false,
    this.conf = '',
  });

  final String decodeMode;
  final bool gpuNext;
  final String conf;

  factory KotvMpvOpts.fromSettings(Map<String, dynamic> settings, {String? decodeMode}) {
    final decode = (decodeMode ?? '${settings['playerDecode'] ?? 'auto'}').trim();
    return KotvMpvOpts(
      decodeMode: decode.isEmpty ? 'auto' : decode,
      gpuNext: '${settings['mpvGpuNext'] ?? ''}'.toLowerCase() == 'true',
      conf: '${settings['mpvConf'] ?? ''}',
    );
  }

  KotvMpvOpts copyWith({
    String? decodeMode,
    bool? gpuNext,
    String? conf,
  }) {
    return KotvMpvOpts(
      decodeMode: decodeMode ?? this.decodeMode,
      gpuNext: gpuNext ?? this.gpuNext,
      conf: conf ?? this.conf,
    );
  }

  bool get soft => decodeMode == 'soft' || decodeMode == 'software' || decodeMode == 'sw';

  bool get hard =>
      decodeMode == 'hard' || decodeMode == 'hardware' || decodeMode == 'hw';

  /// 供 setProperty / VideoController 使用的 hwdec 值。
  ///
  /// PC / Android 默认走硬解**直出**（非 *-copy）。Windows 上部分 HEVC 直播
  /// （如咪咕 HLS）用 d3d11va 直出会卡死 UI，见 [applyAfterAttach] 对 hevc 的排除。
  String hwdecValue() {
    if (soft) return 'no';
    if (kotvIsAndroid()) {
      // 直出：硬解 mediacodec；自动交给 mpv 选（优先硬解）。
      return hard ? 'mediacodec' : 'auto';
    }
    if (hard) {
      if (!kIsWeb && defaultTargetPlatform == TargetPlatform.windows) {
        // Win7 多为 dxva2 直出；Win10+ d3d11va 直出。
        return kotvIsWindows7() ? 'dxva2' : 'd3d11va';
      }
      if (!kIsWeb && defaultTargetPlatform == TargetPlatform.macOS) {
        return 'videotoolbox';
      }
    }
    return 'auto';
  }

  /// Android 可切 gpu/gpu-next；桌面必须 libmpv（Flutter Texture）。
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
      // 勿改 vo：NativeVideoController 默认 libmpv，换 gpu-next 会黑屏
      hwdec: hw,
      enableHardwareAcceleration: !soft,
    );
  }

  /// 在 VideoController 已附着之后调用：缓冲预算 + conf。
  Future<void> applyAfterAttach(Player player) async {
    try {
      final platform = player.platform;
      if (platform == null) return;
      Future<void> set(String k, String v) async {
        await (platform as dynamic).setProperty(k, v);
      }

      try {
        await set('hwdec', hwdecValue());
      } catch (_) {}

      // Windows：H.264 等保持硬解直出；HEVC 直出在部分直播（咪咕 HLS）会卡死整窗 UI，
      // 故不把 hevc 交给 d3d11va，改走软解。fengshows 实为 FLV/H264，仍走直出。
      if (!soft && !kIsWeb && defaultTargetPlatform == TargetPlatform.windows) {
        try {
          await set('hwdec-codecs', 'h264,vc1,wmv3,mpeg2video,vp9,av1');
        } catch (_) {}
      }

      try {
        await KotvBufferBudget.warm(force: true);
        final budget = KotvBufferBudget.bytes();
        final forward = KotvBufferBudget.mpvMiB(budget);
        final back = KotvBufferBudget.mpvMiB(max(16 * 1024 * 1024, budget ~/ 8));
        await set('cache', 'yes');
        await set('cache-on-disk', 'no');
        await set('demuxer-max-bytes', forward);
        await set('demuxer-max-back-bytes', back);
        await set('demuxer-readahead-secs', '1000000');
        await set('cache-secs', '1000000');
        await set('framedrop', 'vo');
      } catch (_) {}

      for (final e in parseConfLines(conf)) {
        await set(e.$1, e.$2);
      }
    } catch (_) {}
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
      // 跳过会破坏 Flutter Texture 输出的选项
      if (key == 'vo' || key == 'wid' || key == 'android-surface-size') continue;
      out.add((key, value.isEmpty ? 'yes' : value));
    }
    return out;
  }
}
