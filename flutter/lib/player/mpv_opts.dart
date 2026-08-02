import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'kotv_platform.dart';

/// MPV / media_kit 选项：解码 + Vulkan / gpu-next / conf。
///
/// ## 平台能力
/// | 选项 | Android | 桌面 (PC) |
/// |------|---------|-----------|
/// | hwdec | ✅ mediacodec-copy / auto-safe / no | ✅ auto / no（系统硬解） |
/// | mpv.conf | ✅ 事后 setProperty | ✅ 同上 |
/// | Vulkan | ⚠️ 事后覆盖（media_kit 写死 android EGL） | ⚠️ 可设 gpu-api=vulkan；vo 仍须 libmpv |
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
      return hard ? 'mediacodec-copy' : 'auto-safe';
    }
    // 桌面：auto 让 libmpv 选 d3d11va / videotoolbox / vaapi 等
    return hard ? 'auto' : 'auto';
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

  /// VideoController 附着后应用 Vulkan / conf。
  Future<void> applyAfterAttach(Player player) async {
    try {
      final platform = player.platform;
      if (platform == null) return;
      Future<void> set(String k, String v) async {
        await (platform as dynamic).setProperty(k, v);
      }
      if (vulkan) {
        await set('gpu-api', 'vulkan');
        if (kotvIsAndroid()) {
          await set('gpu-context', 'androidvk');
        } else if (!kIsWeb && Platform.isLinux) {
          // 桌面 Vulkan 常见 context；失败则忽略
          await set('gpu-context', 'waylandvk');
        } else if (!kIsWeb && Platform.isWindows) {
          await set('gpu-context', 'winvk');
        }
      }
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
