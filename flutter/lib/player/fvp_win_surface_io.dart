import 'dart:ffi';

import 'package:flutter/painting.dart' show BoxFit;
import 'package:flutter/services.dart';
// fvp 没有公开 mdk 句柄与 updateNativeSurface；Win7 原生壳只能从这两处拿。
// ignore: implementation_imports
import 'package:fvp/src/fvp_platform_interface.dart';
// ignore: implementation_imports
import 'package:fvp/src/generated_bindings.dart' show mdkPlayerAPI;
import 'package:video_player/video_player.dart';

import 'video_scale_fit.dart';

/// Win7：FVP（libmdk）直接画进原生子 HWND（与 mpv 共用 `kotv_mpv` 的槽几何、显隐和裁剪），
/// 原生播控、手势层与 mpv 完全同一套；Flutter 纹理在 Win7 子窗口下面看不到。
class KotvFvpWinSurface {
  KotvFvpWinSurface._();

  static const _ch = MethodChannel('kotv_mpv');
  static _HandleTap? _tap;

  /// 须在第一个 [VideoPlayerController] 建纹理前装上。
  static void install() {
    if (_tap != null) return;
    final tap = _HandleTap(FvpPlatform.instance);
    FvpPlatform.instance = tap;
    _tap = tap;
  }

  static int? _playerId(VideoPlayerController c) {
    final d = c as dynamic;
    try {
      return d.playerId as int;
    } catch (_) {}
    try {
      return d.textureId as int;
    } catch (_) {}
    return null;
  }

  static mdkPlayerAPI? _api(VideoPlayerController c) {
    final id = _playerId(c);
    final handle = id == null ? null : _tap?.handles[id];
    if (handle == null || handle == 0) return null;
    return Pointer<mdkPlayerAPI>.fromAddress(handle).ref;
  }

  /// mdk setAspectRatio：0 拉伸、+ε 适应、-ε 裁切填满、其它正数为强制画幅。
  static double aspectFor(String scale) {
    const eps = 1.1920928955078125e-7;
    final forced = kotvForcedAspectRatio(scale);
    if (forced != null) return forced;
    switch (kotvFitFromVideoScale(scale, BoxFit.contain)) {
      case BoxFit.fill:
        return 0;
      case BoxFit.cover:
        return -eps;
      default:
        return eps;
    }
  }

  /// 返回绑定的 mdk 对象地址（解绑用）；拿不到句柄时 null。
  static Future<int?> bind(VideoPlayerController c, String scale) async {
    final api = _api(c);
    if (api == null) return null;
    final object = api.object.address;
    try {
      final ok = await _ch.invokeMethod<bool>('mdkBind', {
        'object': object,
        'surface': api.updateNativeSurface.address,
        'aspectFn': api.setAspectRatio.address,
        'aspect': aspectFor(scale),
      });
      return ok == true ? object : null;
    } catch (_) {
      return null;
    }
  }

  static Future<void> setScale(String scale) async {
    try {
      await _ch.invokeMethod('mdkAspect', {'aspect': aspectFor(scale)});
    } catch (_) {}
  }

  static Future<void> unbind(int object) async {
    try {
      await _ch.invokeMethod('mdkUnbind', {'object': object});
    } catch (_) {}
  }
}

class _HandleTap extends FvpPlatform {
  _HandleTap(this._inner);

  final FvpPlatform _inner;

  /// 纹理 id（即 VideoPlayerController 的 playerId）→ mdkPlayerAPI*。
  final handles = <int, int>{};

  @override
  Future<String?> getPlatformVersion() => _inner.getPlatformVersion();

  @override
  Future<int> createTexture(int playerHandle, int width, int height, bool tunnel) async {
    final id = await _inner.createTexture(playerHandle, width, height, tunnel);
    handles[id] = playerHandle;
    return id;
  }

  @override
  Future<void> releaseTexture(int playerHandle, int textureId) =>
      _inner.releaseTexture(playerHandle, textureId);

  @override
  Future<void> releasePlayer(int playerHandle) {
    handles.removeWhere((_, h) => h == playerHandle);
    return _inner.releasePlayer(playerHandle);
  }

  @override
  Future<void> setMixWithOthers(bool mixWithOthers) => _inner.setMixWithOthers(mixWithOthers);
}
