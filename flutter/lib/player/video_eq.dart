import 'package:flutter/painting.dart';

/// 画面调色（MPV / media_kit / FVP 全量；Exo：Surface/Texture 均走 Media3 setVideoEffects）。
///
/// 数值：brightness/contrast/saturation/gamma/hue/temperature/shadow ∈ [-100, 100]，0 为中性；
/// sharpness ∈ [0, 100]。隧道模式 / HDR 下 Exo 效果不可用。
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

  /// soft / vivid / off；其它当自定义读独立键。
  factory KotvVideoEq.fromSettings(Map<String, dynamic> settings) {
    final preset = '${settings['videoEq'] ?? 'off'}'.trim().toLowerCase();
    switch (preset) {
      case 'soft':
        return const KotvVideoEq(
          enabled: true,
          brightness: 5,
          contrast: -5,
          saturation: -10,
        );
      case 'vivid':
        return const KotvVideoEq(
          enabled: true,
          contrast: 10,
          saturation: 20,
          sharpness: 15,
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
      // 阴影抬升：正值提亮暗部。
      final lift = (sw / 100.0 * 0.15).toStringAsFixed(3);
      parts.add('lavfi=[eq=gamma_r=${1.0 + double.parse(lift)}:gamma_g=${1.0 + double.parse(lift)}:gamma_b=${1.0 + double.parse(lift)}]');
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
    // 色温近似：正值偏暖（加红减蓝）。
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

/// 简易音频均衡预设 → mpv `af` / FVP `audio.avfilter`。
enum KotvAudioEqPreset { off, bass, voice, custom }

KotvAudioEqPreset kotvAudioEqFromSettings(Map<String, dynamic> settings) {
  switch ('${settings['audioEq'] ?? 'off'}'.trim().toLowerCase()) {
    case 'bass':
      return KotvAudioEqPreset.bass;
    case 'voice':
      return KotvAudioEqPreset.voice;
    case 'custom':
      return KotvAudioEqPreset.custom;
    default:
      return KotvAudioEqPreset.off;
  }
}

/// 自定义频段：`freq:gain,freq:gain…`（如 `80:6,1000:3,3000:2`）。
String kotvAudioEqBandsFromSettings(Map<String, dynamic> settings) {
  return '${settings['audioEqBands'] ?? ''}'.trim();
}

bool kotvAudioDialogueFromSettings(Map<String, dynamic> settings) {
  final v = '${settings['audioDialogue'] ?? ''}'.trim().toLowerCase();
  return v == 'true' || v == '1' || v == 'on' || v == 'yes';
}

/// 声道平衡 ∈ [-100, 100]；负偏左、正偏右、0 居中。
int kotvAudioBalanceFromSettings(Map<String, dynamic> settings) {
  final n = int.tryParse('${settings['audioBalance'] ?? '0'}') ?? 0;
  return n.clamp(-100, 100);
}

String _bandsToLavfi(String bands) {
  final parts = <String>[];
  for (final raw in bands.split(',')) {
    final kv = raw.trim().split(':');
    if (kv.length != 2) continue;
    final f = double.tryParse(kv[0].trim());
    final g = double.tryParse(kv[1].trim());
    if (f == null || g == null || f <= 0) continue;
    final width = (f * 0.4).clamp(40.0, 800.0).toStringAsFixed(0);
    parts.add('equalizer=f=${f.toStringAsFixed(0)}:t=h:width=$width:g=${g.toStringAsFixed(1)}');
  }
  if (parts.isEmpty) return '';
  return 'lavfi=[${parts.join(',')}]';
}

/// mpv af 字符串；空 = 清掉。
String kotvAudioEqMpvAf(KotvAudioEqPreset p, {String bands = ''}) {
  switch (p) {
    case KotvAudioEqPreset.bass:
      return 'lavfi=[equalizer=f=80:t=h:width=80:g=6]';
    case KotvAudioEqPreset.voice:
      return 'lavfi=[equalizer=f=1000:t=h:width=400:g=4,equalizer=f=3000:t=h:width=800:g=2]';
    case KotvAudioEqPreset.custom:
      return _bandsToLavfi(bands);
    case KotvAudioEqPreset.off:
      return '';
  }
}

/// 组合 EQ + 对白增强 + 声道平衡为一条 mpv `af`（直通时应传空）。
String kotvComposeMpvAf({
  KotvAudioEqPreset eq = KotvAudioEqPreset.off,
  String bands = '',
  bool dialogue = false,
  int balance = 0,
}) {
  final inners = <String>[];
  void addLavfi(String lavfi) {
    final s = lavfi.trim();
    if (s.isEmpty) return;
    if (s.startsWith('lavfi=[') && s.endsWith(']')) {
      final inner = s.substring(7, s.length - 1).trim();
      if (inner.isNotEmpty) inners.add(inner);
    } else {
      inners.add(s);
    }
  }

  addLavfi(kotvAudioEqMpvAf(eq, bands: bands));
  if (dialogue) {
    // 人声频段抬升 + 轻压缩，避免 dialoguenhance 输出 3.0 声道。
    inners.add(
      'equalizer=f=1200:t=h:width=900:g=5,'
      'equalizer=f=2800:t=h:width=1400:g=3,'
      'acompressor=threshold=-22dB:ratio=2.2:attack=12:release=180:makeup=2.5',
    );
  }
  final b = balance.clamp(-100, 100);
  if (b != 0) {
    final left = b <= 0 ? 1.0 : (1.0 - b / 100.0);
    final right = b >= 0 ? 1.0 : (1.0 + b / 100.0);
    inners.add(
      'pan=stereo|c0=${left.toStringAsFixed(3)}*c0|c1=${right.toStringAsFixed(3)}*c1',
    );
  }
  if (inners.isEmpty) return '';
  return 'lavfi=[${inners.join(',')}]';
}

String kotvAudioEqFvpFilter(
  KotvAudioEqPreset p, {
  String bands = '',
  bool dialogue = false,
  int balance = 0,
}) {
  final af = kotvComposeMpvAf(eq: p, bands: bands, dialogue: dialogue, balance: balance);
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
    case KotvAudioEqPreset.off:
      return 'off';
  }
}
