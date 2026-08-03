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

  /// 探测 libmpv 能否真正切到 Vulkan（写入设置前调用；失败应保持关闭）。
  static Future<(bool ok, String detail)> probeVulkan() async {
    if (kIsWeb) return (false, '当前平台不支持');
    Player? player;
    try {
      MediaKit.ensureInitialized();
      player = Player();
      final platform = player.platform;
      if (platform == null) return (false, 'MPV 后端不可用');

      Future<void> set(String k, String v) async {
        await (platform as dynamic).setProperty(k, v);
      }

      Future<String> get(String k) async {
        try {
          return '${await (platform as dynamic).getProperty(k)}'.trim();
        } catch (_) {
          return '';
        }
      }

      await set('gpu-api', 'vulkan');
      if (kotvIsAndroid()) {
        await set('gpu-context', 'androidvk');
      } else if (Platform.isWindows) {
        await set('gpu-context', 'winvk');
      } else if (Platform.isLinux) {
        try {
          await set('gpu-context', 'waylandvk');
        } catch (_) {
          await set('gpu-context', 'x11vk');
        }
      } else if (Platform.isMacOS) {
        try {
          await set('gpu-context', 'macvk');
        } catch (_) {}
      }

      // 给 mpv 一点时间消化属性
      await Future<void>.delayed(const Duration(milliseconds: 80));
      final api = (await get('gpu-api')).toLowerCase();
      if (api.isEmpty) {
        return (false, '无法读取 gpu-api（当前 libmpv 可能未暴露该属性）');
      }
      if (!api.contains('vulkan')) {
        return (false, '未生效（gpu-api=$api）');
      }
      final ctx = await get('gpu-context');
      final detail = ctx.isEmpty ? 'gpu-api=$api' : 'gpu-api=$api · context=$ctx';
      return (true, detail);
    } catch (e) {
      return (false, '$e');
    } finally {
      try {
        await player?.dispose();
      } catch (_) {}
    }
  }

  /// VideoController 附着后应用 Vulkan / conf（对齐 TV MpvUtil.addVideoOutputOptions）。
  /// 返回是否按预期生效；[vulkan]==true 但读回非 vulkan 时为 false。
  Future<bool> applyAfterAttach(Player player) async {
    try {
      final platform = player.platform;
      if (platform == null) return !vulkan;
      Future<void> set(String k, String v) async {
        await (platform as dynamic).setProperty(k, v);
      }

      Future<String> get(String k) async {
        try {
          return '${await (platform as dynamic).getProperty(k)}'.trim();
        } catch (_) {
          return '';
        }
      }

      if (vulkan) {
        // 对齐 TV：gpu-api=vulkan + 平台 context（TV 用 androidvk pre-init）
        await set('gpu-api', 'vulkan');
        if (kotvIsAndroid()) {
          await set('gpu-context', 'androidvk');
        } else if (!kIsWeb && Platform.isLinux) {
          try {
            await set('gpu-context', 'waylandvk');
          } catch (_) {
            await set('gpu-context', 'x11vk');
          }
        } else if (!kIsWeb && Platform.isWindows) {
          await set('gpu-context', 'winvk');
        }
        await Future<void>.delayed(const Duration(milliseconds: 40));
        final api = (await get('gpu-api')).toLowerCase();
        if (!api.contains('vulkan')) return false;
      }

      for (final e in parseConfLines(conf)) {
        await set(e.$1, e.$2);
      }
      return true;
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
