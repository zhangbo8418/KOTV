import 'dart:math' show max;

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'buffer_budget.dart';
import 'kotv_platform.dart';

/// MPV / media_kit 选项：解码 + Vulkan / gpu-next / conf。
///
/// ## 平台能力
/// | 选项 | Android | 桌面 (PC) |
/// |------|---------|-----------|
/// | hwdec | ✅ mediacodec-copy / auto-safe / no | ✅ auto / no（系统硬解） |
/// | mpv.conf | ✅ 事后 setProperty | ✅ 同上 |
/// | Vulkan | ❌ media_kit EGL 路径起播后切 androidvk 会 abort | ❌ Texture 强制 vo=libmpv |
/// | gpu-next | ✅ vo=gpu-next | ❌ Flutter Texture 必须 vo=libmpv，开启无效 |
class KotvMpvOpts {
  const KotvMpvOpts({
    this.decodeMode = 'auto',
    this.vulkan = false,
    this.gpuNext = false,
    this.conf = '',
  });

  final String decodeMode;
  final bool vulkan;
  final bool gpuNext;
  final String conf;

  factory KotvMpvOpts.fromSettings(Map<String, dynamic> settings, {String? decodeMode}) {
    final decode = (decodeMode ?? '${settings['playerDecode'] ?? 'auto'}').trim();
    return KotvMpvOpts(
      decodeMode: decode.isEmpty ? 'auto' : decode,
      vulkan: '${settings['mpvVulkan'] ?? ''}'.toLowerCase() == 'true',
      gpuNext: '${settings['mpvGpuNext'] ?? ''}'.toLowerCase() == 'true',
      conf: '${settings['mpvConf'] ?? ''}',
    );
  }

  KotvMpvOpts copyWith({
    String? decodeMode,
    bool? vulkan,
    bool? gpuNext,
    String? conf,
  }) {
    return KotvMpvOpts(
      decodeMode: decodeMode ?? this.decodeMode,
      vulkan: vulkan ?? this.vulkan,
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
      // mediacodec（零拷贝）在不少机型起播即 abort；copy 走 CPU 回读更稳。
      // 硬解优先 copy；auto 用 auto-safe 让 libmpv 自己退避。
      return hard ? 'mediacodec-copy' : 'auto-safe';
    }
    // 桌面：auto 让 libmpv 选 d3d11va / videotoolbox / vaapi 等
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

  /// 探测能否启用 Vulkan（写入设置前）。
  ///
  /// 桌面 Texture / Android media_kit EGL Surface 路径均无法在起播后安全切 androidvk。
  static Future<(bool ok, String detail)> probeVulkan() async {
    if (kIsWeb) return (false, '当前平台不支持');
    if (!kotvIsAndroid()) {
      return (
        false,
        '桌面内置 MPV 通过 Flutter Texture 出画（vo=libmpv / ANGLE），无法切换 Vulkan',
      );
    }
    // 无 Surface 时 setProperty 可能「看起来成功」，但 VC 附着后切 androidvk 会进程 abort。
    return (
      false,
      '当前内置 MPV 由 media_kit 绑定 EGL Surface，起播后无法安全切换 Vulkan（会闪退）',
    );
  }

  /// 在 VideoController 已附着之后调用：先缓冲预算，再（Android）覆盖 media_kit 写死的 EGL。
  Future<bool> applyAfterAttach(Player player) async {
    try {
      final platform = player.platform;
      if (platform == null) return !vulkan;
      Future<void> set(String k, String v) async {
        await (platform as dynamic).setProperty(k, v);
      }

      // 内存水位：demuxer-max-bytes 为前向上限；播过的包释放后继续补满。
      // 时长类（readahead/cache-secs）拉满，避免按秒数卡预读；回看内存用 back-bytes 限制。
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

      // Vulkan：media_kit 已绑 EGL；中途切 androidvk 会 abort。设置开启也不在此切换。
      final vulkanOk = !vulkan;

      for (final e in parseConfLines(conf)) {
        await set(e.$1, e.$2);
      }
      return vulkanOk;
    } catch (_) {
      return !vulkan;
    }
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
