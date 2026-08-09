import 'dart:math' show max;

import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'buffer_budget.dart';
import 'kotv_platform.dart';

/// MPV / media_kit 选项：解码 / gpu-next / conf。
///
/// ## 平台能力
/// | 选项 | Android | 桌面 (PC) |
/// |------|---------|-----------|
/// | hwdec | ✅ mediacodec-copy / auto-safe / no | ✅ auto / no |
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
  String hwdecValue() {
    if (soft) return 'no';
    if (kotvIsAndroid()) {
      // mediacodec 零拷贝在不少机型 abort；copy 更稳（安卓已验证）。
      return hard ? 'mediacodec-copy' : 'auto-safe';
    }
    // 桌面：与 8/8 基线一致，交给 libmpv auto。
    // dxva2-copy / auto-copy 曾试过：今早 d23f24b 已实测「未解决」并撤回，勿再臆测钉死。
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
        // 钉死 hwdec，避免 media_kit/conf 又改回零拷贝。
        await set('hwdec', hwdecValue());
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
      // 跳过会破坏 Flutter Texture 输出的选项；hwdec 由 hwdecValue 统一钉死
      if (key == 'vo' || key == 'wid' || key == 'android-surface-size' || key == 'hwdec') {
        continue;
      }
      out.add((key, value.isEmpty ? 'yes' : value));
    }
    return out;
  }
}
