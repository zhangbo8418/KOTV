import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'buffer_budget.dart';
import 'kotv_playback.dart';
import 'kotv_platform.dart';
import 'video_eq.dart';

/// 交给 lavf 的 demuxer 选项。302 / HLS 子列表由播放器自己跟，不要在 Dart 里预跳。
///
/// **不要写 protocol_whitelist**：一旦写了就是拒绝名单外的协议。
/// 旧写法 `file\,http` 还会被拆成 `file\`，HLS 嵌套 https 也挂。
/// 不设则 lavf 默认放行 RTSP/RTMP/RTP/MMS/HTTP/HLS 等。
const kotvDemuxerLavfO =
    'seg_max_retry=5,strict=experimental,'
    'allowed_extensions=ALL,allowed_segment_extensions=ALL,extension_picky=0,'
    'probesize=8000000,analyzeduration=8000000';

/// 空列表：不要按后缀把 URL 当播放列表 / 图片。
/// 网关常把 FLV/TS 写成 .m3u8、把 TS 分片写成 .png；交给 lavf 按内容探测。
const kotvPlaylistExts = '';
const kotvImageExts = '';

/// MPV 选项：Android 走原生插件；桌面/Windows/macOS 走 media_kit + 自带 libmpv。
///
/// 自带 libmpv 由 scripts 编译（Vulkan 硬解、AV3A 等）；Flutter 侧不挂 wid/Surface。
/// FVP 为独立内置播放器，与 MPV 并列可选。
///
/// ## 平台能力
/// | 选项 | Android 原生 | 桌面 media_kit |
/// |------|-------------|----------------|
/// | hwdec | 硬=直出；自动=直出硬解优先再软解（全平台禁用 auto-safe/copy） |
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
    this.tlsVerify = true,
    this.audioPassThrough = true,
    this.diskCache = false,
    this.dolbyVisionPolicy = 0,
    this.preferredTextLangs = '',
    this.videoEq = KotvVideoEq.off,
    this.audioEq = KotvAudioEqPreset.off,
    this.audioEqBands = '',
    this.audioDialogue = false,
    this.audioBalance = 0,
    this.subtitleFontScale = 1.0,
  });

  final String decodeMode;
  final bool gpuNext;
  final bool vulkan;
  /// Windows：`auto` / `d3d11` / `opengl` / `vulkan`。
  final String gpuApi;
  final String conf;
  /// Android 原生：HTTPS 校验证书（cacert.pem）；坏 CA 可关。
  final bool tlsVerify;
  final bool audioPassThrough;
  final bool diskCache;
  /// 对齐 exoDolbyVision：0=AUTO 1=假定支持 2=假定不支持。
  final int dolbyVisionPolicy;
  /// 首选字幕语言 → mpv slang。
  final String preferredTextLangs;
  final KotvVideoEq videoEq;
  final KotvAudioEqPreset audioEq;
  /// 自定义频段 `freq:gain,…`。
  final String audioEqBands;
  /// 对白增强（人声频段 + 轻压缩）。
  final bool audioDialogue;
  /// 声道平衡 ∈ [-100, 100]。
  final int audioBalance;
  /// mpv `sub-scale`（0.5–2.5）。
  final double subtitleFontScale;

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
    // 默认开；显式 false/off/0/no 才关。
    final tlsVerify = kotvSettingsFlag(settings['mpvTlsVerify'] ?? 'true', def: true);
    final audioPassThrough = kotvSettingsFlag(settings['audioPassThrough'] ?? 'true', def: true);
    final diskCache = kotvSettingsFlag(settings['mpvDiskCache'] ?? 'false', def: false);
    var dolby = int.tryParse('${settings['exoDolbyVision'] ?? '0'}') ?? 0;
    if (dolby < 0 || dolby > 2) dolby = 0;
    final preferredTextLangs = '${settings['exoPreferredTextLangs'] ?? ''}'.trim();
    var fontScale = double.tryParse('${settings['subtitleFontScale'] ?? '1.0'}') ?? 1.0;
    fontScale = fontScale.clamp(0.5, 2.5);
    return KotvMpvOpts(
      decodeMode: decode.isEmpty ? 'auto' : decode,
      gpuNext: gpuNext,
      vulkan: vulkan,
      gpuApi: gpuApi,
      conf: '${settings['mpvConf'] ?? ''}',
      tlsVerify: tlsVerify,
      audioPassThrough: audioPassThrough,
      diskCache: diskCache,
      dolbyVisionPolicy: dolby,
      preferredTextLangs: preferredTextLangs,
      videoEq: KotvVideoEq.fromSettings(settings),
      audioEq: kotvAudioEqFromSettings(settings),
      audioEqBands: kotvAudioEqBandsFromSettings(settings),
      audioDialogue: kotvAudioDialogueFromSettings(settings),
      audioBalance: kotvAudioBalanceFromSettings(settings),
      subtitleFontScale: fontScale,
    );
  }

  KotvMpvOpts copyWith({
    String? decodeMode,
    bool? gpuNext,
    bool? vulkan,
    String? gpuApi,
    String? conf,
    bool? tlsVerify,
    bool? audioPassThrough,
    bool? diskCache,
    int? dolbyVisionPolicy,
    String? preferredTextLangs,
    KotvVideoEq? videoEq,
    KotvAudioEqPreset? audioEq,
    String? audioEqBands,
    bool? audioDialogue,
    int? audioBalance,
    double? subtitleFontScale,
  }) {
    return KotvMpvOpts(
      decodeMode: decodeMode ?? this.decodeMode,
      gpuNext: gpuNext ?? this.gpuNext,
      vulkan: vulkan ?? this.vulkan,
      gpuApi: gpuApi ?? this.gpuApi,
      conf: conf ?? this.conf,
      tlsVerify: tlsVerify ?? this.tlsVerify,
      audioPassThrough: audioPassThrough ?? this.audioPassThrough,
      diskCache: diskCache ?? this.diskCache,
      dolbyVisionPolicy: dolbyVisionPolicy ?? this.dolbyVisionPolicy,
      preferredTextLangs: preferredTextLangs ?? this.preferredTextLangs,
      videoEq: videoEq ?? this.videoEq,
      audioEq: audioEq ?? this.audioEq,
      audioEqBands: audioEqBands ?? this.audioEqBands,
      audioDialogue: audioDialogue ?? this.audioDialogue,
      audioBalance: audioBalance ?? this.audioBalance,
      subtitleFontScale: subtitleFontScale ?? this.subtitleFontScale,
    );
  }

  bool get soft => decodeMode == 'soft' || decodeMode == 'software' || decodeMode == 'sw';

  bool get hard =>
      decodeMode == 'hard' || decodeMode == 'hardware' || decodeMode == 'hw';

  /// 供 setProperty / VideoController 使用的 hwdec 值。
  ///
  /// 「自动」= 优先**直出**硬解，失败再软解；UI 仍显示自动。
  /// 全平台不用 `auto` / `auto-safe`（常选 *-copy，Texture/嵌入路径会卡顿掉帧）。
  String hwdecValue() {
    if (soft) return 'no';
    if (kotvIsAndroid()) {
      // 硬解锁 mediacodec；自动 = 直出硬解，不行再软解（原生 RK 也会覆盖为 mediacodec）
      return hard ? 'mediacodec' : 'mediacodec,no';
    }
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.windows) {
      if (kotvIsWindows7()) {
        return hard ? 'dxva2' : 'dxva2,no';
      }
      return hard ? 'd3d11va' : 'd3d11va,dxva2,no';
    }
    if (!kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.macOS ||
            defaultTargetPlatform == TargetPlatform.iOS)) {
      return hard ? 'videotoolbox' : 'videotoolbox,no';
    }
    // Linux 等：直出硬解链，自动再兜底软解
    const linuxHw = 'vaapi,vulkan,nvdec,cuda,vdpau';
    return hard ? linuxHw : '$linuxHw,no';
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

      // HLS 伪装扩展名；不设 protocol_whitelist（名单外的 RTSP/RTMP 会被拒）。
      try {
        await set('demuxer-lavf-o', kotvDemuxerLavfO);
      } catch (_) {}
      try {
        await set('ytdl', 'no');
      } catch (_) {}
      try {
        await set('playlist-exts', kotvPlaylistExts);
      } catch (_) {}
      try {
        await set('image-exts', kotvImageExts);
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

      if (live) {
        // 直播不写 demuxer-max-bytes / cache-secs；关掉 cache-pause 避免播一段停一段。
        try {
          await set('cache-pause', 'no');
        } catch (_) {}
      } else {
        try {
          await KotvBufferBudget.warm(force: true);
          final props = KotvBufferBudget.mpvCacheProps(KotvBufferBudget.bytes());
          for (final e in props.entries) {
            await set(e.key, e.value);
          }
          await set('cache-on-disk', diskCache ? 'yes' : 'no');
          if (preferredTextLangs.trim().isNotEmpty) {
            final slang = preferredTextLangs.replaceAll(';', ',').replaceAll(RegExp(r'\s+'), '');
            await set('slang', slang);
          }
        } catch (_) {}
      }

      for (final e in parseConfLines(conf)) {
        await set(e.$1, e.$2);
      }

      // 画面/音频 EQ 放在 conf 之后，避免被托管外的 af 盖掉；直通时不写 af。
      for (final e in videoEq.mpvProps().entries) {
        try {
          await set(e.key, e.value);
        } catch (_) {}
      }
      final vf = videoEq.mpvVf();
      try {
        await set('vf', vf);
      } catch (_) {}
      if (!audioPassThrough) {
        try {
          await set(
            'af',
            kotvComposeMpvAf(
              eq: audioEq,
              bands: audioEqBands,
              dialogue: audioDialogue,
              balance: audioBalance,
            ),
          );
        } catch (_) {}
      }
      try {
        await set('sub-scale', subtitleFontScale.clamp(0.5, 2.5).toStringAsFixed(2));
      } catch (_) {}
    } catch (_) {}
  }

  /// 交给原生通道的属性表（P1/P2 open / setOpts）。
  ///
  /// [live]=true：不写 demuxer-max-bytes / cache-secs。
  Map<String, String> propertyMap({bool live = false}) {
    final out = <String, String>{
      'hwdec': hwdecValue(),
      'demuxer-lavf-o': kotvDemuxerLavfO,
      'ytdl': 'no',
      'playlist-exts': kotvPlaylistExts,
      'image-exts': kotvImageExts,
    };
    if (live) {
      out['cache-pause'] = 'no';
    }
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
      final props = KotvBufferBudget.mpvCacheProps(KotvBufferBudget.bytes());
      out.addAll(props);
      // Android 原生另有 diskCache 参数写 cache-on-disk + demuxer-cache-dir；
      // 桌面 media_kit 走 [applyAfterAttach]。此处不塞 cache-on-disk，避免盖掉原生磁盘缓存。
    }
    for (final e in parseConfLines(conf)) {
      out[e.$1] = e.$2;
    }
    out.addAll(videoEq.mpvProps());
    out['sub-scale'] = subtitleFontScale.clamp(0.5, 2.5).toStringAsFixed(2);
    return out;
  }

  /// 原生通道 open/setOpts 附加的 EQ 参数。
  Map<String, dynamic> equalizerChannelArgs() => {
        'eqBrightness': videoEq.enabled ? videoEq.brightness : 0,
        'eqContrast': videoEq.enabled ? videoEq.contrast : 0,
        'eqSaturation': videoEq.enabled ? videoEq.saturation : 0,
        'eqGamma': videoEq.enabled ? videoEq.gamma : 0,
        'eqHue': videoEq.enabled ? videoEq.hue : 0,
        'audioAf': audioPassThrough
            ? ''
            : kotvComposeMpvAf(
                eq: audioEq,
                bands: audioEqBands,
                dialogue: audioDialogue,
                balance: audioBalance,
              ),
        'videoVf': videoEq.mpvVf(),
        'subtitleFontScale': subtitleFontScale.clamp(0.5, 2.5),
      };

  /// UI / 引擎托管、写入 mpv.conf 会被忽略的选项（对齐 FongMi `MpvUtil.PLAYER_OPTIONS` 等）。
  static const managedOptionNames = <String>{
    'vo',
    'wid',
    'android-surface-size',
    'gpu-api',
    'gpu-context',
    'hwdec',
    'audio-spdif',
    'android-dolby-vision-output',
    'demuxer-dovi-profile7',
    'cache',
    'cache-on-disk',
    'demuxer-cache-dir',
    'cache-secs',
    'demuxer-max-bytes',
    'demuxer-max-back-bytes',
    'cache-pause',
    'cache-pause-initial',
    'tls-verify',
    'tls-ca-file',
    'slang',
    'brightness',
    'contrast',
    'saturation',
    'gamma',
    'hue',
  };

  /// conf 里与 UI 托管冲突的键名（用于设置页提示）。
  static List<String> findConfConflicts(String text) {
    final hit = <String>{};
    for (final e in parseConfLines(text, skipManaged: false)) {
      final k = e.$1;
      final base = k.startsWith('no-') ? k.substring(3) : k;
      if (managedOptionNames.contains(base) || managedOptionNames.contains(k)) {
        hit.add(base);
      }
    }
    final out = hit.toList()..sort();
    return out;
  }

  /// 解析 mpv.conf 风格：`key=value` / `key value`；忽略空行与 `#` 注释。
  ///
  /// [skipManaged]=true（默认）：跳过 UI 托管键，避免 conf 盖掉设置页/引擎策略。
  static List<(String, String)> parseConfLines(String text, {bool skipManaged = true}) {
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
      // `kotv-*` 是应用自用开关（如 kotv-log=debug），不是 mpv 属性。
      if (key.startsWith('kotv-')) continue;
      if (skipManaged) {
        final base = key.startsWith('no-') ? key.substring(3) : key;
        if (managedOptionNames.contains(key) || managedOptionNames.contains(base)) {
          continue;
        }
      }
      out.add((key, value.isEmpty ? 'yes' : value));
    }
    return out;
  }
}
