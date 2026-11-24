import 'dart:convert';

import 'kotv_playback.dart';
import 'kotv_platform.dart';
import 'play_format.dart';
import 'playback_settings.dart';
import 'player_normalize.dart';
import 'video_eq.dart';

/// 交给 lavf 的 demuxer 选项。302 / HLS 子列表由播放器自己跟，不要在 Dart 里预跳。
///
/// **不要写 protocol_whitelist**：一旦写了就是拒绝名单外的协议。
/// 旧写法 `file\,http` 还会被拆成 `file\`，HLS 嵌套 https 也挂。
/// 不设则 lavf 默认放行 RTSP/RTMP/RTP/MMS/HTTP/HLS 等。
/// 与安卓 [KotvAndroidPlayback.LAVF_DEMUXER_O] 同串；改一处须同步另一处。
const kotvDemuxerLavfO =
    'seg_max_retry=5,strict=experimental,'
    'allowed_extensions=ALL,allowed_segment_extensions=ALL,extension_picky=0,'
    'probesize=8000000,analyzeduration=8000000';

/// HLS lavf 附加：URI 已是 HLS 时只加 `http_persistent=0`；
/// 仅靠 mime/format 认 HLS（无扩展名代理）时再加 `extension_picky=0`。
const kotvHlsLavfOAddForUri = 'http_persistent=0';
const kotvHlsLavfOAddForMime = 'extension_picky=0,http_persistent=0';

/// 开播 lavf：仅当 URI/mime 为 HLS 时设 `demuxer-lavf-format=hls` + o-add。
/// 非 HLS 不写空 format（不主动清空）；[lavfO] 为会话基线（含 ClearKey）。
Future<void> kotvApplyLavfForOpen({
  required Future<void> Function(String key, String value) set,
  required String url,
  String? format,
  required String lavfO,
}) async {
  await set('demuxer-lavf-o', lavfO);
  if (!kotvIsHls(url, format)) return;
  await set('demuxer-lavf-format', 'hls');
  final add = kotvUrlIsHls(url) ? kotvHlsLavfOAddForUri : kotvHlsLavfOAddForMime;
  await set('demuxer-lavf-o-add', add);
}

/// loadfile 一次性选项：仅 HLS 时追加 `demuxer-lavf-format` / `demuxer-lavf-o-add`。
/// 与安卓 [KotvAndroidPlayback.appendLavfHlsLoadOpts] 同语义。
void kotvAppendLavfHlsLoadOpts(
  String url,
  String? mimeOrFormat,
  List<String> opts,
) {
  if (!kotvIsHls(url, mimeOrFormat)) return;
  opts.add('demuxer-lavf-format=hls');
  final add =
      kotvUrlIsHls(url) ? kotvHlsLavfOAddForUri : kotvHlsLavfOAddForMime;
  opts.add('demuxer-lavf-o-add=$add');
}

/// mpv loadfile 选项串：按 UTF-8 字节长度包一层，避免值里的 `=` / `,` 被拆开。
String kotvEncodeMpvLoadfileOptions(List<String> options) {
  if (options.isEmpty) return '';
  return options.map((option) {
    final eq = option.indexOf('=');
    if (eq <= 0) return kotvEncodeMpvLoadfilePart(option);
    final key = option.substring(0, eq);
    final value = option.substring(eq + 1);
    return '${kotvEncodeMpvLoadfilePart(key)}=${kotvEncodeMpvLoadfilePart(value)}';
  }).join(',');
}

String kotvEncodeMpvLoadfilePart(String value) {
  final n = utf8.encode(value).length;
  return '%$n%$value';
}

/// FVP/mdk 侧与 [kotvDemuxerLavfO] 同源的探测窗口（avformat.*）。
Map<String, String> kotvFvpAvformatProbeOpts() => const {
      'avformat.probesize': '8000000',
      'avformat.analyzeduration': '8000000',
      'avformat.extension_picky': '0',
      'avformat.allowed_extensions': 'ALL',
      'avformat.allowed_segment_extensions': 'ALL',
    };

/// 空列表：不要按后缀把 URL 当播放列表 / 图片。
/// 网关常把 FLV/TS 写成 .m3u8、把 TS 分片写成 .png；交给 lavf 按内容探测。
const kotvPlaylistExts = '';
const kotvImageExts = '';

/// MPV 选项：原生 `kotv_mpv`（Android / macOS / iOS / Windows / Linux）。
///
/// 自带 libmpv 由 scripts 自编译（Vulkan、AV3A、macOS vo_avfoundation 等），钉 [mpv-build.lock.json]；
/// iOS 用同一提交发布的 MPVKit。FVP 为独立内置播放器，与 MPV 并列可选。
///
/// 原生 MPV 能开 Vulkan 渲染的平台。
bool kotvMpvVulkanSupported() => kotvUsesNativeMpv();

/// Win7「硬解直出」开关的落盘值：按当前会话实际状态取反。详情 / 全屏 / 播控共用。
String kotvWin7DirectNextValue(bool currentlyOn) => currentlyOn ? 'false' : 'true';

class KotvMpvOpts {
  const KotvMpvOpts({
    this.decodeMode = 'auto',
    this.gpuNext = false,
    this.vulkan = false,
    this.conf = '',
    this.tlsVerify = true,
    this.audioPassThrough = true,
    this.diskCache = false,
    this.direct = false,
    this.dolbyVisionPolicy = 0,
    this.preferredTextLangs = '',
    this.videoEq = KotvVideoEq.off,
    this.audioEq = KotvAudioEqPreset.off,
    this.audioEqBands = '',
    this.audioDialogue = 0,
    this.audioBalance = 0,
    this.audioStability = 0,
    this.audioBoost = 0,
    this.audioPreamp = 0,
    this.audioLoudness = false,
    this.audioCenterGain = 0,
    this.stableVolume = false,
    this.audioChannelMode = 'auto',
    this.audioOffsetMs = 0,
    this.subtitleFontScale = 1.0,
  });

  final String decodeMode;
  final bool gpuNext;
  /// Vulkan 渲染（原生端再看设备是否支持）：Android gpu-api=vulkan；macOS gpu-next+MoltenVK；
  /// Win/Linux gpu-api 先试 Vulkan。
  final bool vulkan;
  final String conf;
  /// Android 原生：HTTPS 校验证书（cacert.pem）；坏 CA 可关。
  final bool tlsVerify;
  final bool audioPassThrough;
  final bool diskCache;
  /// Win7 硬解直出（默认关）：开 → `hwdec=dxva2,auto`；关 → `auto`。
  final bool direct;
  /// 杜比视界策略：0=AUTO 1=假定支持 2=假定不支持（与 exoDolbyVision 枚举一致）。
  final int dolbyVisionPolicy;
  /// 首选字幕语言 → mpv slang。
  final String preferredTextLangs;
  final KotvVideoEq videoEq;
  final KotvAudioEqPreset audioEq;
  /// 自定义频段 `freq:gain,…`。
  final String audioEqBands;
  /// 对白增强 0–100。
  final int audioDialogue;
  /// 声道平衡 ∈ [-100, 100]。
  final int audioBalance;
  final int audioStability;
  final int audioBoost;
  final int audioPreamp;
  final bool audioLoudness;
  final int audioCenterGain;
  /// 播放菜单「稳定音量」：音效链里加 dynaudnorm。
  final bool stableVolume;
  final String audioChannelMode;
  /// 音画偏移毫秒（正值声音滞后）。
  final int audioOffsetMs;
  /// mpv `sub-scale`（0.5–2.0）。
  final double subtitleFontScale;

  factory KotvMpvOpts.fromSettings(Map<String, dynamic> settings, {String? decodeMode}) {
    final decode = (decodeMode ?? '${settings['playerDecode'] ?? 'auto'}').trim();
    // gpu/gpu-next 开关只有 Android 有（桌面固定 gpu-next，macOS 默认 avfoundation）。
    final android = kotvIsAndroid();
    final gpuNext = android && '${settings['mpvGpuNext'] ?? ''}'.toLowerCase() == 'true';
    final vulkan = kotvMpvVulkanSupported() && '${settings['mpvVulkan'] ?? ''}'.toLowerCase() == 'true';
    // 默认开；显式 false/off/0/no 才关。
    final tlsVerify = kotvSettingsFlag(settings['mpvTlsVerify'] ?? 'true', def: true);
    // 只有 Android 原生 MPV 写 audio-spdif；其它平台没有直通，不能因此挡掉音效。
    final audioPassThrough = android && kotvSettingsFlag(settings['audioPassThrough'] ?? 'true', def: true);
    final diskCache = kotvSettingsFlag(settings['mpvDiskCache'] ?? 'false', def: false);
    var dolby = kotvDolbyVisionFromSettings(settings);
    if (dolby < 0 || dolby > 2) dolby = 0;
    final preferredTextLangs = kotvPreferredTextLangsFromSettings(settings);
    final fontScale = kotvClampSubtitleFontScale(
      double.tryParse('${settings['subtitleFontScale'] ?? '1.0'}'),
    );
    return KotvMpvOpts(
      decodeMode: decode.isEmpty ? 'auto' : kotvNormalizeDecodeMode(decode),
      gpuNext: gpuNext,
      vulkan: vulkan,
      conf: '${settings['mpvConf'] ?? ''}',
      tlsVerify: tlsVerify,
      audioPassThrough: audioPassThrough,
      diskCache: diskCache,
      direct: kotvSettingsFlag(settings['mpvDirect']),
      dolbyVisionPolicy: dolby,
      preferredTextLangs: preferredTextLangs,
      videoEq: KotvVideoEq.fromSettings(settings),
      audioEq: kotvAudioEqFromSettings(settings),
      audioEqBands: kotvAudioEqBandsFromSettings(settings),
      audioDialogue: kotvAudioDialogueFromSettings(settings),
      audioBalance: kotvAudioBalanceFromSettings(settings),
      audioStability: kotvAudioStabilityFromSettings(settings),
      audioBoost: kotvAudioBoostFromSettings(settings),
      audioPreamp: kotvAudioPreampFromSettings(settings),
      audioLoudness: kotvAudioLoudnessFromSettings(settings),
      audioCenterGain: kotvAudioCenterGainFromSettings(settings),
      stableVolume: kotvSettingsFlag(settings['playerStableVolume'] ?? 'false', def: false),
      audioChannelMode: kotvAudioChannelModeFromSettings(settings),
      audioOffsetMs: kotvAudioOffsetMsFromSettings(settings),
      subtitleFontScale: fontScale,
    );
  }

  KotvMpvOpts copyWith({
    String? decodeMode,
    bool? gpuNext,
    bool? vulkan,
    String? conf,
    bool? tlsVerify,
    bool? audioPassThrough,
    bool? diskCache,
    bool? direct,
    int? dolbyVisionPolicy,
    String? preferredTextLangs,
    KotvVideoEq? videoEq,
    KotvAudioEqPreset? audioEq,
    String? audioEqBands,
    int? audioDialogue,
    int? audioBalance,
    int? audioStability,
    int? audioBoost,
    int? audioPreamp,
    bool? audioLoudness,
    int? audioCenterGain,
    bool? stableVolume,
    String? audioChannelMode,
    int? audioOffsetMs,
    double? subtitleFontScale,
  }) {
    return KotvMpvOpts(
      decodeMode: decodeMode ?? this.decodeMode,
      gpuNext: gpuNext ?? this.gpuNext,
      vulkan: vulkan ?? this.vulkan,
      conf: conf ?? this.conf,
      tlsVerify: tlsVerify ?? this.tlsVerify,
      audioPassThrough: audioPassThrough ?? this.audioPassThrough,
      diskCache: diskCache ?? this.diskCache,
      direct: direct ?? this.direct,
      dolbyVisionPolicy: dolbyVisionPolicy ?? this.dolbyVisionPolicy,
      preferredTextLangs: preferredTextLangs ?? this.preferredTextLangs,
      videoEq: videoEq ?? this.videoEq,
      audioEq: audioEq ?? this.audioEq,
      audioEqBands: audioEqBands ?? this.audioEqBands,
      audioDialogue: audioDialogue ?? this.audioDialogue,
      audioBalance: audioBalance ?? this.audioBalance,
      audioStability: audioStability ?? this.audioStability,
      audioBoost: audioBoost ?? this.audioBoost,
      audioPreamp: audioPreamp ?? this.audioPreamp,
      audioLoudness: audioLoudness ?? this.audioLoudness,
      audioCenterGain: audioCenterGain ?? this.audioCenterGain,
      stableVolume: stableVolume ?? this.stableVolume,
      audioChannelMode: audioChannelMode ?? this.audioChannelMode,
      audioOffsetMs: audioOffsetMs ?? this.audioOffsetMs,
      subtitleFontScale: subtitleFontScale ?? this.subtitleFontScale,
    );
  }

  String _composedAf() => kotvComposeMpvAf(
        eq: audioEq,
        bands: audioEqBands,
        dialogue: audioDialogue,
        balance: audioBalance,
        channelMode: audioChannelMode,
        stability: audioStability,
        boost: audioBoost,
        preamp: audioPreamp,
        loudness: audioLoudness,
        centerGain: audioCenterGain,
        dynamicNorm: stableVolume,
      );

  bool get soft => kotvNormalizeDecodeMode(decodeMode) == 'soft';

  bool get hard => kotvNormalizeDecodeMode(decodeMode) == 'hard';

  /// 全平台唯一 hwdec 字符串（Dart 侧）。原生桌面通道经 create/setDecode/setOpts 下发；
  /// Android 原生仍按 decode 自算（API / 直出），可忽略本值。
  ///
  /// 「自动」= 优先硬解，失败再软解；UI 仍显示自动。
  String hwdecValue() {
    if (soft) return 'no';
    if (kotvIsAndroid()) {
      return hard ? 'mediacodec' : 'mediacodec,no';
    }
    if (kotvIsWindows()) {
      // Win7 直出：先试 dxva2 零拷贝，不行由 mpv 接着自选；关直出与 Win8+ 相同。
      if (kotvIsWindows7() && direct) return 'dxva2,auto';
      return 'auto';
    }
    if (kotvIsApple()) {
      // avfoundation：自动/硬解都走 videotoolbox（软解已在上方返回 no）。
      return 'videotoolbox';
    }
    const linuxHw = 'vaapi,vulkan,nvdec,cuda,vdpau';
    return hard ? linuxHw : '$linuxHw,no';
  }

  /// 按住看原画 / 试听原音要写的属性。不含 hwdec。
  /// 音频直通时不写 af，避免盖掉当前直通。
  Map<String, String> fxPreviewProperties({
    required bool videoOriginal,
    required bool audioOriginal,
  }) {
    final out = <String, String>{};
    if (videoOriginal) {
      out['brightness'] = '0';
      out['contrast'] = '0';
      out['saturation'] = '0';
      out['gamma'] = '0';
      out['hue'] = '0';
      out['vf'] = '';
    } else {
      out.addAll(videoEq.mpvProps());
      out['vf'] = videoEq.mpvVf();
    }
    if (!audioPassThrough) {
      out['af'] = audioOriginal ? '' : _composedAf();
    }
    return out;
  }

  /// 原生通道 open/setOpts 附加的 EQ 参数。
  Map<String, dynamic> equalizerChannelArgs() => {
        'eqBrightness': videoEq.enabled ? videoEq.brightness : 0,
        'eqContrast': videoEq.enabled ? videoEq.contrast : 0,
        'eqSaturation': videoEq.enabled ? videoEq.saturation : 0,
        'eqGamma': videoEq.enabled ? videoEq.gamma : 0,
        'eqHue': videoEq.enabled
            ? (videoEq.hue + videoEq.temperature ~/ 2).clamp(-100, 100)
            : 0,
        'eqSharpness': videoEq.enabled ? videoEq.sharpness : 0,
        'audioAf': _composedAf(),
        'videoVf': videoEq.mpvVf(),
        'subtitleFontScale': subtitleFontScale.clamp(0.5, 2.0),
      };

  /// UI / 引擎托管、写入 mpv.conf 会被忽略的选项。
  static const managedOptionNames = <String>{
    'vo',
    'wid',
    'android-surface-size',
    'gpu-api',
    'gpu-context',
    'hwdec',
    'audio-spdif',
    'android-dolby-vision-output',
    'avfoundation-presentation',
    'avfoundation-composite-osd',
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
      // `kotv-*` 是应用自用开关，不是 mpv 属性。
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
