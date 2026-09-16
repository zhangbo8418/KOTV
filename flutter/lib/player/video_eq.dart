import 'package:flutter/painting.dart';

/// 画面调色（MPV / media_kit / FVP 全量；Exo：Texture 渲染用 ColorMatrix，SurfaceView 忽略画面）。
///
/// 数值对齐 mpv：brightness/contrast/saturation/gamma/hue ∈ [-100, 100]，0 为中性。
class KotvVideoEq {
  const KotvVideoEq({
    this.enabled = false,
    this.brightness = 0,
    this.contrast = 0,
    this.saturation = 0,
    this.gamma = 0,
    this.hue = 0,
  });

  final bool enabled;
  final int brightness;
  final int contrast;
  final int saturation;
  final int gamma;
  final int hue;

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
        );
      default:
        return off;
    }
  }

  /// mpv 属性表（关闭时全部写回 0）。
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
      'hue': '${hue.clamp(-100, 100)}',
    };
  }

  /// FVP / mdk：`video.avfilter=eq=...`（关闭时空串）。
  String fvpAvfilter() {
    if (!enabled) return '';
    // mpv 的 ±100 ≈ lavfi eq 的 brightness≈±1、contrast/saturation 倍率。
    final b = (brightness.clamp(-100, 100) / 100.0).toStringAsFixed(3);
    final c = (1.0 + contrast.clamp(-100, 100) / 100.0).clamp(0.1, 3.0).toStringAsFixed(3);
    final s = (1.0 + saturation.clamp(-100, 100) / 100.0).clamp(0.0, 3.0).toStringAsFixed(3);
    final g = (1.0 + gamma.clamp(-100, 100) / 100.0).clamp(0.1, 3.0).toStringAsFixed(3);
    return 'eq=brightness=$b:contrast=$c:saturation=$s:gamma=$g';
  }

  /// Exo Flutter Texture 路径的画面滤镜；关闭或全 0 时返回 null。
  ColorFilter? exoTextureColorFilter() {
    if (!enabled) return null;
    final b = brightness.clamp(-100, 100) / 100.0;
    final c = (1.0 + contrast.clamp(-100, 100) / 100.0).clamp(0.1, 3.0);
    final s = (1.0 + saturation.clamp(-100, 100) / 100.0).clamp(0.0, 3.0);
    if (b.abs() < 0.001 && (c - 1.0).abs() < 0.001 && (s - 1.0).abs() < 0.001) {
      return null;
    }
    // 先对比度+亮度，再饱和度（标准 ColorMatrix 组合）。
    final t = (1.0 - c) * 0.5 + b;
    final invS = 1.0 - s;
    const lr = 0.2126, lg = 0.7152, lb = 0.0722;
    final r = lr * invS;
    final g = lg * invS;
    final bl = lb * invS;
    return ColorFilter.matrix(<double>[
      c * (r + s), c * g, c * bl, 0, t * 255,
      c * r, c * (g + s), c * bl, 0, t * 255,
      c * r, c * g, c * (bl + s), 0, t * 255,
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
enum KotvAudioEqPreset { off, bass, voice }

KotvAudioEqPreset kotvAudioEqFromSettings(Map<String, dynamic> settings) {
  switch ('${settings['audioEq'] ?? 'off'}'.trim().toLowerCase()) {
    case 'bass':
      return KotvAudioEqPreset.bass;
    case 'voice':
      return KotvAudioEqPreset.voice;
    default:
      return KotvAudioEqPreset.off;
  }
}

/// mpv af 字符串；空 = 清掉。
String kotvAudioEqMpvAf(KotvAudioEqPreset p) {
  switch (p) {
    case KotvAudioEqPreset.bass:
      return 'lavfi=[equalizer=f=80:t=h:width=80:g=6]';
    case KotvAudioEqPreset.voice:
      return 'lavfi=[equalizer=f=1000:t=h:width=400:g=4,equalizer=f=3000:t=h:width=800:g=2]';
    case KotvAudioEqPreset.off:
      return '';
  }
}

String kotvAudioEqFvpFilter(KotvAudioEqPreset p) {
  switch (p) {
    case KotvAudioEqPreset.bass:
      return 'equalizer=f=80:t=h:width=80:g=6';
    case KotvAudioEqPreset.voice:
      return 'equalizer=f=1000:t=h:width=400:g=4,equalizer=f=3000:t=h:width=800:g=2';
    case KotvAudioEqPreset.off:
      return '';
  }
}

/// Exo 原生通道 `audioEq` 参数。
String kotvAudioEqExoMode(KotvAudioEqPreset p) {
  switch (p) {
    case KotvAudioEqPreset.bass:
      return 'bass';
    case KotvAudioEqPreset.voice:
      return 'voice';
    case KotvAudioEqPreset.off:
      return 'off';
  }
}
