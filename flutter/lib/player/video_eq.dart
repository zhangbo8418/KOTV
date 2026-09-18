import 'dart:math' as math;

import 'package:flutter/painting.dart';

/// 画面调色（MPV / media_kit / FVP 全量；Exo：Surface/Texture 均走 Media3 setVideoEffects）。
///
/// 数值：brightness/contrast/saturation/gamma/hue/temperature/shadow ∈ [-100, 100]，0 为中性；
/// sharpness ∈ [0, 100]。隧道模式 / HDR 下 Exo 效果不可用。
///
/// 预设数值由 TV `VideoEffectProfile` 换算：sat/con→(x-1)*100，bri→*100，
/// sharp/shadow→*100，gamma→(x-1)*200，temperature 原样，hue→/1.8。
class KotvVideoEq {
  const KotvVideoEq({
    this.enabled = false,
    this.brightness = 0,
    this.contrast = 0,
    this.saturation = 0,
    this.gamma = 0,
    this.hue = 0,
    this.temperature = 0,
    this.sharpness = 0,
    this.shadow = 0,
  });

  final bool enabled;
  final int brightness;
  final int contrast;
  final int saturation;
  final int gamma;
  final int hue;
  final int temperature;
  final int sharpness;
  final int shadow;

  static const off = KotvVideoEq();

  /// 预设 id → 中文标签（设置 UI）。
  static const presetLabels = <String, String>{
    'off': '关闭',
    'natural': '自然',
    'vivid': '鲜艳',
    'clear': '清晰',
    'bright': '明亮',
    'cinema': '影院',
    'soft': '柔和',
    'warm': '暖色',
    'cool': '冷色',
    'comfort': '舒适',
    'anime': '动漫',
    'sport': '运动',
    'game': '游戏',
    'custom': '自定义',
  };

  factory KotvVideoEq.fromSettings(Map<String, dynamic> settings) {
    final preset = '${settings['videoEq'] ?? 'off'}'.trim().toLowerCase();
    switch (preset) {
      case 'natural':
        return const KotvVideoEq(enabled: true, saturation: 2, contrast: 2, sharpness: 4);
      case 'vivid':
        return const KotvVideoEq(
          enabled: true,
          saturation: 26,
          contrast: 12,
          brightness: 1,
          sharpness: 14,
        );
      case 'clear':
        return const KotvVideoEq(
          enabled: true,
          saturation: 4,
          contrast: 12,
          sharpness: 36,
          shadow: 2,
        );
      case 'bright':
        return const KotvVideoEq(
          enabled: true,
          saturation: 4,
          contrast: 5,
          brightness: 1,
          sharpness: 4,
          shadow: 6,
          gamma: 2,
        );
      case 'cinema':
        return const KotvVideoEq(
          enabled: true,
          saturation: 4,
          contrast: 14,
          brightness: -3,
          sharpness: 3,
          shadow: 3,
          gamma: -6,
          temperature: 26,
        );
      case 'soft':
        return const KotvVideoEq(
          enabled: true,
          saturation: -5,
          contrast: -6,
          brightness: 1,
          shadow: 5,
          gamma: 6,
          temperature: 14,
        );
      case 'warm':
        return const KotvVideoEq(
          enabled: true,
          saturation: 5,
          contrast: 4,
          sharpness: 3,
          shadow: 2,
          temperature: 42,
        );
      case 'cool':
        return const KotvVideoEq(
          enabled: true,
          saturation: 4,
          contrast: 5,
          sharpness: 3,
          shadow: 2,
          temperature: -42,
        );
      case 'comfort':
        return const KotvVideoEq(
          enabled: true,
          saturation: -8,
          contrast: -7,
          brightness: -1,
          shadow: 6,
          gamma: 8,
          temperature: 58,
        );
      case 'anime':
        return const KotvVideoEq(
          enabled: true,
          saturation: 24,
          contrast: 10,
          brightness: 2,
          sharpness: 28,
          shadow: 2,
        );
      case 'sport':
        return const KotvVideoEq(
          enabled: true,
          saturation: 12,
          contrast: 14,
          brightness: 2,
          sharpness: 24,
          shadow: 4,
        );
      case 'game':
        return const KotvVideoEq(
          enabled: true,
          saturation: 8,
          contrast: 14,
          brightness: 2,
          sharpness: 30,
          shadow: 4,
        );
      case 'custom':
      case 'on':
        return KotvVideoEq(
          enabled: true,
          brightness: _i(settings['videoBrightness'], 0),
          contrast: _i(settings['videoContrast'], 0),
          saturation: _i(settings['videoSaturation'], 0),
          gamma: _i(settings['videoGamma'], 0),
          hue: _i(settings['videoHue'], 0),
          temperature: _i(settings['videoTemperature'], 0),
          sharpness: _i(settings['videoSharpness'], 0).clamp(0, 100),
          shadow: _i(settings['videoShadow'], 0),
        );
      default:
        return off;
    }
  }

  /// mpv 属性表（关闭时全部写回 0）；锐度/阴影走 vf。
  Map<String, String> mpvProps() {
    if (!enabled) {
      return const {
        'brightness': '0',
        'contrast': '0',
        'saturation': '0',
        'gamma': '0',
        'hue': '0',
      };
    }
    return {
      'brightness': '${brightness.clamp(-100, 100)}',
      'contrast': '${contrast.clamp(-100, 100)}',
      'saturation': '${saturation.clamp(-100, 100)}',
      'gamma': '${gamma.clamp(-100, 100)}',
      'hue': '${(hue + temperature ~/ 2).clamp(-100, 100)}',
    };
  }

  /// mpv `vf` 附加（锐度 / 阴影抬升）；空串表示清掉。
  String mpvVf() {
    if (!enabled) return '';
    final parts = <String>[];
    final sh = sharpness.clamp(0, 100);
    if (sh > 0) {
      final amount = (sh / 100.0 * 1.5).toStringAsFixed(2);
      parts.add('lavfi=[unsharp=5:5:$amount:5:5:0]');
    }
    final sw = shadow.clamp(-100, 100);
    if (sw.abs() > 0) {
      final lift = (sw / 100.0 * 0.15).toStringAsFixed(3);
      parts.add(
        'lavfi=[eq=gamma_r=${1.0 + double.parse(lift)}:gamma_g=${1.0 + double.parse(lift)}:gamma_b=${1.0 + double.parse(lift)}]',
      );
    }
    return parts.join(',');
  }

  /// FVP / mdk：`video.avfilter=eq=...`（关闭时空串）。
  String fvpAvfilter() {
    if (!enabled) return '';
    final b = (brightness.clamp(-100, 100) / 100.0).toStringAsFixed(3);
    final c = (1.0 + contrast.clamp(-100, 100) / 100.0).clamp(0.1, 3.0).toStringAsFixed(3);
    final s = (1.0 + saturation.clamp(-100, 100) / 100.0).clamp(0.0, 3.0).toStringAsFixed(3);
    final g = (1.0 + gamma.clamp(-100, 100) / 100.0).clamp(0.1, 3.0).toStringAsFixed(3);
    final parts = <String>['eq=brightness=$b:contrast=$c:saturation=$s:gamma=$g'];
    final sh = sharpness.clamp(0, 100);
    if (sh > 0) {
      final amount = (sh / 100.0 * 1.5).toStringAsFixed(2);
      parts.add('unsharp=5:5:$amount:5:5:0');
    }
    return parts.join(',');
  }

  /// Exo Flutter Texture 兜底滤镜（隧道等原生 effects 不可用时）；关闭或全 0 时返回 null。
  ColorFilter? exoTextureColorFilter() {
    if (!enabled) return null;
    final b = brightness.clamp(-100, 100) / 100.0;
    final c = (1.0 + contrast.clamp(-100, 100) / 100.0).clamp(0.1, 3.0);
    final s = (1.0 + saturation.clamp(-100, 100) / 100.0).clamp(0.0, 3.0);
    final temp = temperature.clamp(-100, 100) / 100.0 * 0.12;
    if (b.abs() < 0.001 &&
        (c - 1.0).abs() < 0.001 &&
        (s - 1.0).abs() < 0.001 &&
        temp.abs() < 0.001) {
      return null;
    }
    final t = (1.0 - c) * 0.5 + b;
    final invS = 1.0 - s;
    const lr = 0.2126, lg = 0.7152, lb = 0.0722;
    final r = lr * invS;
    final g = lg * invS;
    final bl = lb * invS;
    return ColorFilter.matrix(<double>[
      c * (r + s) + temp, c * g, c * bl - temp * 0.5, 0, t * 255,
      c * r, c * (g + s), c * bl, 0, t * 255,
      c * r - temp * 0.5, c * g, c * (bl + s) - temp, 0, t * 255,
      0, 0, 0, 1, 0,
    ]);
  }

  static int _i(dynamic v, int def) {
    final n = int.tryParse('$v');
    if (n == null) return def;
    return n.clamp(-100, 100);
  }
}

/// 音频均衡预设（含 TV 常用档）。
enum KotvAudioEqPreset {
  off,
  natural,
  voice,
  cinema,
  bass,
  treble,
  pop,
  rock,
  dance,
  electronic,
  hiphop,
  jazz,
  classical,
  custom,
}

KotvAudioEqPreset kotvAudioEqFromSettings(Map<String, dynamic> settings) {
  switch ('${settings['audioEq'] ?? 'off'}'.trim().toLowerCase()) {
    case 'natural':
      return KotvAudioEqPreset.natural;
    case 'voice':
    case 'vocal':
      return KotvAudioEqPreset.voice;
    case 'cinema':
      return KotvAudioEqPreset.cinema;
    case 'bass':
      return KotvAudioEqPreset.bass;
    case 'treble':
      return KotvAudioEqPreset.treble;
    case 'pop':
      return KotvAudioEqPreset.pop;
    case 'rock':
      return KotvAudioEqPreset.rock;
    case 'dance':
      return KotvAudioEqPreset.dance;
    case 'electronic':
      return KotvAudioEqPreset.electronic;
    case 'hiphop':
      return KotvAudioEqPreset.hiphop;
    case 'jazz':
      return KotvAudioEqPreset.jazz;
    case 'classical':
      return KotvAudioEqPreset.classical;
    case 'custom':
      return KotvAudioEqPreset.custom;
    default:
      return KotvAudioEqPreset.off;
  }
}

/// 自定义频段：`freq:gain,freq:gain…`（如 `80:6,1000:3,3000:2`），gain 单位 dB。
String kotvAudioEqBandsFromSettings(Map<String, dynamic> settings) {
  return '${settings['audioEqBands'] ?? ''}'.trim();
}

/// 对白增强 0–100；兼容旧布尔 `true`→100。
int kotvAudioDialogueFromSettings(Map<String, dynamic> settings) {
  final v = '${settings['audioDialogue'] ?? ''}'.trim().toLowerCase();
  if (v.isEmpty || v == 'false' || v == '0' || v == 'off' || v == 'no') return 0;
  if (v == 'true' || v == 'on' || v == 'yes') return 100;
  return (int.tryParse(v) ?? 0).clamp(0, 100);
}

/// 声道平衡 ∈ [-100, 100]；负偏左、正偏右、0 居中。
int kotvAudioBalanceFromSettings(Map<String, dynamic> settings) {
  final n = int.tryParse('${settings['audioBalance'] ?? '0'}') ?? 0;
  return n.clamp(-100, 100);
}

int kotvAudioStabilityFromSettings(Map<String, dynamic> settings) {
  return (int.tryParse('${settings['audioStability'] ?? '0'}') ?? 0).clamp(0, 100);
}

int kotvAudioBoostFromSettings(Map<String, dynamic> settings) {
  return (int.tryParse('${settings['audioBoost'] ?? '0'}') ?? 0).clamp(0, 1200);
}

int kotvAudioPreampFromSettings(Map<String, dynamic> settings) {
  return (int.tryParse('${settings['audioPreamp'] ?? '0'}') ?? 0).clamp(-1200, 0);
}

bool kotvAudioLoudnessFromSettings(Map<String, dynamic> settings) {
  final v = '${settings['audioLoudness'] ?? ''}'.trim().toLowerCase();
  return v == 'true' || v == '1' || v == 'on' || v == 'yes';
}

int kotvAudioCenterGainFromSettings(Map<String, dynamic> settings) {
  return (int.tryParse('${settings['audioCenterGain'] ?? '0'}') ?? 0).clamp(0, 1200);
}

/// auto / stereo / mono / reverse
String kotvAudioChannelModeFromSettings(Map<String, dynamic> settings) {
  switch ('${settings['audioChannelMode'] ?? 'auto'}'.trim().toLowerCase()) {
    case 'stereo':
    case '1':
      return 'stereo';
    case 'mono':
    case '2':
      return 'mono';
    case 'reverse':
    case '3':
      return 'reverse';
    default:
      return 'auto';
  }
}

/// 音画偏移毫秒 ∈ [-10000, 10000]；正值声音滞后画面。
int kotvAudioOffsetMsFromSettings(Map<String, dynamic> settings) {
  return (int.tryParse('${settings['audioOffsetMs'] ?? '0'}') ?? 0).clamp(-10000, 10000);
}

/// STANDARD 中心频 Hz（与 TV AudioEffectBands.STANDARD 一致）。
const _kStdEqHz = <int>[32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000];

/// TV `AudioPresetLevels.gainFor`（返回 mB/厘倍，÷100 → dB）。
double _presetGainDb(KotvAudioEqPreset p, int hz) {
  int mb;
  switch (p) {
    case KotvAudioEqPreset.natural:
      if (hz < 160) {
        mb = 80;
      } else if (hz < 500) {
        mb = 40;
      } else if (hz < 2000) {
        mb = 0;
      } else if (hz < 6000) {
        mb = 80;
      } else {
        mb = 60;
      }
    case KotvAudioEqPreset.voice:
      if (hz < 160) {
        mb = -180;
      } else if (hz < 600) {
        mb = -80;
      } else if (hz < 1500) {
        mb = 140;
      } else if (hz < 5000) {
        mb = 340;
      } else {
        mb = 100;
      }
    case KotvAudioEqPreset.cinema:
      if (hz < 120) {
        mb = 460;
      } else if (hz < 500) {
        mb = 220;
      } else if (hz < 2500) {
        mb = -80;
      } else if (hz < 7000) {
        mb = 180;
      } else {
        mb = 300;
      }
    case KotvAudioEqPreset.bass:
      if (hz < 120) {
        mb = 600;
      } else if (hz < 300) {
        mb = 460;
      } else if (hz < 700) {
        mb = 180;
      } else if (hz < 2500) {
        mb = -120;
      } else {
        mb = -40;
      }
    case KotvAudioEqPreset.treble:
      if (hz < 160) {
        mb = -180;
      } else if (hz < 700) {
        mb = -80;
      } else if (hz < 2200) {
        mb = 60;
      } else if (hz < 7000) {
        mb = 340;
      } else {
        mb = 520;
      }
    case KotvAudioEqPreset.pop:
      if (hz < 160) {
        mb = 260;
      } else if (hz < 500) {
        mb = 100;
      } else if (hz < 2000) {
        mb = 80;
      } else if (hz < 6000) {
        mb = 280;
      } else {
        mb = 220;
      }
    case KotvAudioEqPreset.rock:
      if (hz < 160) {
        mb = 380;
      } else if (hz < 600) {
        mb = 140;
      } else if (hz < 2500) {
        mb = 60;
      } else if (hz < 7000) {
        mb = 340;
      } else {
        mb = 260;
      }
    case KotvAudioEqPreset.dance:
      if (hz < 120) {
        mb = 560;
      } else if (hz < 300) {
        mb = 400;
      } else if (hz < 1200) {
        mb = -160;
      } else if (hz < 5000) {
        mb = 220;
      } else {
        mb = 400;
      }
    case KotvAudioEqPreset.electronic:
      if (hz < 120) {
        mb = 440;
      } else if (hz < 500) {
        mb = 140;
      } else if (hz < 2200) {
        mb = -120;
      } else if (hz < 7000) {
        mb = 280;
      } else {
        mb = 520;
      }
    case KotvAudioEqPreset.hiphop:
      if (hz < 120) {
        mb = 600;
      } else if (hz < 500) {
        mb = 340;
      } else if (hz < 2000) {
        mb = -100;
      } else if (hz < 6000) {
        mb = 120;
      } else {
        mb = 220;
      }
    case KotvAudioEqPreset.jazz:
      if (hz < 120) {
        mb = 140;
      } else if (hz < 500) {
        mb = 160;
      } else if (hz < 1800) {
        mb = 120;
      } else if (hz < 6000) {
        mb = 260;
      } else {
        mb = 140;
      }
    case KotvAudioEqPreset.classical:
      if (hz < 160) {
        mb = 40;
      } else if (hz < 800) {
        mb = 100;
      } else if (hz < 3000) {
        mb = 140;
      } else if (hz < 9000) {
        mb = 220;
      } else {
        mb = 100;
      }
    case KotvAudioEqPreset.off:
    case KotvAudioEqPreset.custom:
      mb = 0;
  }
  return mb / 100.0;
}

/// TV `AudioSetting.getDialogueLevel`（milliHz 入，返回 mB 增量）。
double _dialogueLevelMb(int milliHz, int dialogue) {
  if (dialogue <= 0) return 0;
  final hz = milliHz ~/ 1000;
  if (hz <= 0) return 0;
  if (hz < 180) return -180.0 * dialogue / 100.0;
  if (hz < 500) return -80.0 * dialogue / 100.0;
  final octaves = (math.log(hz / 2500.0) / math.ln2).abs();
  final weight = math.max(0.0, 1.0 - octaves / 2.0);
  return weight * 650.0 * dialogue / 100.0;
}

String _bandsToLavfi(Map<int, double> hzToDb) {
  final parts = <String>[];
  final keys = hzToDb.keys.toList()..sort();
  for (final f in keys) {
    final g = hzToDb[f]!;
    if (g.abs() < 0.05) continue;
    final width = (f * 0.4).clamp(40.0, 800.0).toStringAsFixed(0);
    parts.add('equalizer=f=$f:t=h:width=$width:g=${g.toStringAsFixed(1)}');
  }
  if (parts.isEmpty) return '';
  return parts.join(',');
}

Map<int, double> _eqBandMap(KotvAudioEqPreset p, {String bands = '', int dialogue = 0}) {
  final map = <int, double>{};
  if (p == KotvAudioEqPreset.custom) {
    for (final raw in bands.split(',')) {
      final kv = raw.trim().split(':');
      if (kv.length != 2) continue;
      final f = int.tryParse(kv[0].trim());
      final g = double.tryParse(kv[1].trim());
      if (f == null || g == null || f <= 0) continue;
      map[f] = g;
    }
  } else if (p != KotvAudioEqPreset.off) {
    for (final hz in _kStdEqHz) {
      map[hz] = _presetGainDb(p, hz);
    }
  }
  if (dialogue > 0) {
    for (final hz in _kStdEqHz) {
      final add = _dialogueLevelMb(hz * 1000, dialogue) / 100.0;
      map[hz] = (map[hz] ?? 0) + add;
    }
    // 自定义频点也叠对白（按最近标准频近似跳过；仅对标准带加）
  }
  return map;
}

String kotvAudioEqMpvAf(KotvAudioEqPreset p, {String bands = '', int dialogue = 0}) {
  return _bandsToLavfi(_eqBandMap(p, bands: bands, dialogue: dialogue));
}

String _channelModeLavfi(String mode) {
  switch (mode) {
    case 'mono':
      return 'pan=stereo|c0=0.5*c0+0.5*c1|c1=0.5*c0+0.5*c1';
    case 'reverse':
      return 'pan=stereo|c0=c1|c1=c0';
    case 'stereo':
      // 多声道下行立体声近似；双声道则近似恒等。
      return 'pan=stereo|c0=c0|c1=c1';
    default:
      return '';
  }
}

String _balanceLavfi(int balance) {
  final b = balance.clamp(-100, 100);
  if (b == 0) return '';
  final left = b <= 0 ? 1.0 : (1.0 - b / 100.0);
  final right = b >= 0 ? 1.0 : (1.0 + b / 100.0);
  return 'pan=stereo|c0=${left.toStringAsFixed(3)}*c0|c1=${right.toStringAsFixed(3)}*c1';
}

String _stabilityLavfi(int stability) {
  if (stability <= 0) return '';
  final amount = stability / 100.0;
  final thresholdDb = (-22 + 6 * amount).toStringAsFixed(1);
  final ratio = (1.4 + 2.6 * amount).toStringAsFixed(2);
  final makeup = (1.0 + 0.8 * amount).toStringAsFixed(2);
  return 'acompressor=threshold=${thresholdDb}dB:ratio=$ratio:attack=12:release=180:makeup=$makeup';
}

/// 组合 EQ / 对白 / 声道 / 稳定 / 增益 / 响度为一条 mpv `af`（直通时应传空）。
String kotvComposeMpvAf({
  KotvAudioEqPreset eq = KotvAudioEqPreset.off,
  String bands = '',
  int dialogue = 0,
  int balance = 0,
  String channelMode = 'auto',
  int stability = 0,
  int boost = 0,
  int preamp = 0,
  bool loudness = false,
  int centerGain = 0,
}) {
  final inners = <String>[];
  void add(String s) {
    final t = s.trim();
    if (t.isNotEmpty) inners.add(t);
  }

  // 中置增益：仅 5.1/7.1；立体声源忽略。
  if (centerGain > 0) {
    final g = math.pow(10.0, centerGain / 2000.0).toDouble();
    add(
      'pan=5.1|c0=c0|c1=c1|c2=${g.toStringAsFixed(3)}*c2|c3=c3|c4=c4|c5=c5',
    );
  }

  final mode = _channelModeLavfi(channelMode);
  if (mode.isNotEmpty && channelMode != 'auto') add(mode);

  final bal = _balanceLavfi(channelMode == 'mono' ? 0 : balance);
  if (bal.isNotEmpty) add(bal);

  if (loudness) {
    add('loudnorm=I=-18:LRA=11:TP=-1.5');
  }

  final stab = _stabilityLavfi(stability);
  if (stab.isNotEmpty) add(stab);

  // boost/preamp：TV volume 滤镜单位为 level/100 dB
  if (boost != 0) add('volume=${(boost / 100.0).toStringAsFixed(2)}dB');
  if (preamp != 0) add('volume=${(preamp / 100.0).toStringAsFixed(2)}dB');

  final eqInner = kotvAudioEqMpvAf(eq, bands: bands, dialogue: dialogue);
  if (eqInner.isNotEmpty) add(eqInner);

  if (boost > 0 || preamp != 0 || loudness || stability > 0 || dialogue > 0 || eq != KotvAudioEqPreset.off) {
    // 抬升后限幅，避免削顶
    if (boost > 0 || loudness || dialogue > 40) {
      add('alimiter=limit=0.98');
    }
  }

  if (inners.isEmpty) return '';
  return 'lavfi=[${inners.join(',')}]';
}

String kotvAudioEqFvpFilter(
  KotvAudioEqPreset p, {
  String bands = '',
  int dialogue = 0,
  int balance = 0,
  String channelMode = 'auto',
  int stability = 0,
  int boost = 0,
  int preamp = 0,
  bool loudness = false,
  int centerGain = 0,
}) {
  final af = kotvComposeMpvAf(
    eq: p,
    bands: bands,
    dialogue: dialogue,
    balance: balance,
    channelMode: channelMode,
    stability: stability,
    boost: boost,
    preamp: preamp,
    loudness: loudness,
    centerGain: centerGain,
  );
  if (af.startsWith('lavfi=[') && af.endsWith(']')) {
    return af.substring(7, af.length - 1);
  }
  return af;
}

/// Exo 原生通道 `audioEq` 参数。
String kotvAudioEqExoMode(KotvAudioEqPreset p) {
  switch (p) {
    case KotvAudioEqPreset.bass:
      return 'bass';
    case KotvAudioEqPreset.voice:
      return 'voice';
    case KotvAudioEqPreset.custom:
      return 'custom';
    case KotvAudioEqPreset.natural:
      return 'natural';
    case KotvAudioEqPreset.cinema:
      return 'cinema';
    case KotvAudioEqPreset.treble:
      return 'treble';
    case KotvAudioEqPreset.pop:
      return 'pop';
    case KotvAudioEqPreset.rock:
      return 'rock';
    case KotvAudioEqPreset.dance:
      return 'dance';
    case KotvAudioEqPreset.electronic:
      return 'electronic';
    case KotvAudioEqPreset.hiphop:
      return 'hiphop';
    case KotvAudioEqPreset.jazz:
      return 'jazz';
    case KotvAudioEqPreset.classical:
      return 'classical';
    case KotvAudioEqPreset.off:
      return 'off';
  }
}

/// 供 Exo 自定义频段字符串（含对白叠加入 dB），空则无 EQ。
String kotvAudioEqExoBandsPayload({
  required KotvAudioEqPreset eq,
  String bands = '',
  int dialogue = 0,
}) {
  final map = _eqBandMap(eq, bands: bands, dialogue: dialogue);
  if (map.isEmpty) return '';
  return map.entries.map((e) => '${e.key}:${e.value.toStringAsFixed(1)}').join(',');
}
