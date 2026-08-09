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
/// | hwdec | ✅ mediacodec / auto-safe / no | ✅ auto / no（系统硬解） |
/// | mpv.conf | ✅ 事后 setProperty | ✅ 同上 |
/// | Vulkan | ⚠️ VC 附着后覆盖 EGL→androidvk（视机型） | ❌ Texture 强制 vo=libmpv，无法 Vulkan |
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
    // Win7：裸 auto 易摸到 d3d11va → 黑屏/卡 UI；钉 dxva2-copy。
    if (kotvIsWindows7()) return 'dxva2-copy';
    // 其它桌面：auto 让 libmpv 选 d3d11va / videotoolbox / vaapi 等
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
  /// 桌面：media_kit 出画强制 `vo=libmpv`（ANGLE/D3D/Metal Texture），**无法**走 mpv Vulkan VO。
  /// Android：`vo=gpu` + Surface 嵌入，可在 VC 附着后尝试 `androidvk`（视 GPU/驱动）。
  static Future<(bool ok, String detail)> probeVulkan() async {
    if (kIsWeb) return (false, '当前平台不支持');
    if (!kotvIsAndroid()) {
      return (
        false,
        '桌面内置 MPV 通过 Flutter Texture 出画（vo=libmpv / ANGLE），无法切换 Vulkan；仅 Android 可尝试',
      );
    }

    Player? player;
    try {
      MediaKit.ensureInitialized();
      player = Player();
      final platform = player.platform;
      if (platform == null) return (false, 'MPV 后端不可用');

      await platform.waitForPlayerInitialization.timeout(const Duration(seconds: 8));

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

      // 无 Surface 时无法完整初始化 androidvk；能写入属性即视为本机 libmpv 认 Vulkan。
      await set('vo', 'gpu');
      await set('gpu-api', 'vulkan');
      await set('gpu-context', 'androidvk');
      await Future<void>.delayed(const Duration(milliseconds: 120));

      final api = (await get('gpu-api')).toLowerCase();
      final ctx = (await get('gpu-context')).toLowerCase();
      if (api.contains('vulkan') || ctx.contains('androidvk') || ctx.contains('vulkan')) {
        final detail = [
          if (api.isNotEmpty) 'gpu-api=$api',
          if (ctx.isNotEmpty) 'context=$ctx',
        ].join(' · ');
        return (true, detail.isEmpty ? 'libmpv 接受 Vulkan 属性' : detail);
      }
      // 部分 libmpv 读回为空但仍接受 set：允许开启，起播后再覆盖 EGL
      if (api.isEmpty && ctx.isEmpty) {
        return (true, '属性读回为空，将在起播后尝试 androidvk（若黑屏请关闭）');
      }
      return (false, '未生效（gpu-api=$api context=$ctx）。本机 libmpv 可能未编进 Vulkan/libplacebo');
    } catch (e) {
      return (false, '$e');
    } finally {
      try {
        await player?.stop();
      } catch (_) {}
      await Future<void>.delayed(const Duration(milliseconds: 200));
      try {
        await player?.dispose();
      } catch (_) {}
    }
  }

  /// 在 VideoController 已附着之后调用：先缓冲预算，再（Android）覆盖 media_kit 写死的 EGL。
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

      // Vulkan 仅在开启时覆盖 media_kit 写死的 EGL；关闭时不要再改 gpu-api/vo，
      // 否则与 AndroidVideoController 并行 setProperty 易原生闪退。
      var vulkanOk = !vulkan;
      if (kotvIsAndroid() && vulkan) {
        final vo = gpuNext ? 'gpu-next' : 'gpu';
        try {
          await set('vo', 'null');
          await set('gpu-api', 'vulkan');
          await set('gpu-context', 'androidvk');
          await set('opengl-es', 'no');
          await set('vo', vo);
          await Future<void>.delayed(const Duration(milliseconds: 80));
          final api = (await get('gpu-api')).toLowerCase();
          final ctx = (await get('gpu-context')).toLowerCase();
          vulkanOk = api.contains('vulkan') ||
              ctx.contains('androidvk') ||
              ctx.contains('vulkan') ||
              (api.isEmpty && ctx.isEmpty);
        } catch (_) {
          vulkanOk = false;
        }
      } else if (vulkan) {
        // 桌面 Texture 路径无法真正启用；属性写了也不走 Vulkan VO。
        vulkanOk = false;
      }

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
