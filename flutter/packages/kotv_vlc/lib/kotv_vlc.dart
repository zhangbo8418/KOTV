import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// 同进程 libvlc → Flutter Texture。
class KotvVlc {
  static const _ch = MethodChannel('kotv_vlc');

  static bool get isSupported =>
      !kIsWeb && (Platform.isMacOS || Platform.isWindows || Platform.isLinux);

  int? textureId;
  String mode = 'texture';
  bool _loaded = false;

  Future<int> create() async {
    final m = await _ch.invokeMapMethod<String, dynamic>('create') ?? {};
    mode = '${m['mode'] ?? 'texture'}';
    textureId = (m['textureId'] as num?)?.toInt();
    if (textureId == null) throw StateError('kotv_vlc create failed');
    return textureId!;
  }

  Future<void> load({required String libDir, required String pluginDir}) async {
    await _ch.invokeMethod('load', {'libDir': libDir, 'pluginDir': pluginDir});
    _loaded = true;
  }

  Future<void> play(String url) async {
    if (!_loaded) throw StateError('kotv_vlc not loaded');
    await _ch.invokeMethod('play', {'url': url});
  }

  Future<void> stop() => _ch.invokeMethod('stop');
  Future<void> pause() => _ch.invokeMethod('pause');
  Future<void> resume() => _ch.invokeMethod('resume');
  Future<Map<String, dynamic>> toggle() async {
    final m = await _ch.invokeMapMethod<String, dynamic>('toggle') ?? {};
    return Map<String, dynamic>.from(m);
  }

  Future<void> seekMs(int ms) => _ch.invokeMethod('seek', {'ms': ms});
  Future<void> setVolume(int v) => _ch.invokeMethod('volume', {'value': v});
  Future<void> setRate(double r) => _ch.invokeMethod('rate', {'value': r});
  Future<void> setDecodeMode(String mode) => _ch.invokeMethod('decode', {'mode': mode});
  Future<void> setDecodeSoft(bool soft) => setDecodeMode(soft ? 'soft' : 'hard');

  Future<void> setRepeatOne(bool on) => _ch.invokeMethod('repeat', {'on': on});

  /// type: 0=音轨 1=字幕
  Future<Map<String, dynamic>> tracks({required int type}) async {
    final m = await _ch.invokeMapMethod<String, dynamic>('tracks', {'type': type}) ?? {};
    return Map<String, dynamic>.from(m);
  }

  Future<void> setTrack({required int type, required int id}) =>
      _ch.invokeMethod('setTrack', {'type': type, 'id': id});

  Future<Map<String, dynamic>> status() async {
    final m = await _ch.invokeMapMethod<String, dynamic>('status') ?? {};
    return Map<String, dynamic>.from(m);
  }

  Future<void> dispose() async {
    try {
      await _ch.invokeMethod('dispose');
    } catch (_) {}
    textureId = null;
    _loaded = false;
  }
}
