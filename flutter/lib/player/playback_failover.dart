import 'package:flutter/foundation.dart' show kIsWeb;

import '../util/kotv_io.dart';
import 'kotv_platform.dart';

/// 开播黑屏/超时后的会话内回退（各平台同一套，不写死某一引擎）：
/// 1. hard↔soft 翻转；**auto 先改软解重试**（直出硬解失败时的会话内回退）
/// 2. 再按 [innieRing] 换下一个内置播放器，并恢复用户设置的解码
/// 不写回设置里的 `player` / `playerLive` / `playerDecode`。
class KotvPlaybackFailover {
  KotvPlaybackFailover({
    required String playerVal,
    required String decodeMode,
    this.lockExoForDrm = false,
    this.enabled = true,
  })  : settingsDecodeMode = normDecode(decodeMode),
        _playerVal = playerVal.trim(),
        _decodeMode = normDecode(decodeMode);

  /// 用户设置的解码（换播放器时恢复）。
  final String settingsDecodeMode;

  /// Android DRM：禁止离开 Exo。
  final bool lockExoForDrm;

  /// 设置「自动切换播放器」为关闭时不 failover。
  final bool enabled;

  /// `playerFailover`：auto/true/空 = 开；off/false = 关。
  static bool enabledFromSetting(String raw) {
    switch (raw.trim().toLowerCase()) {
      case 'off':
      case 'false':
      case '0':
      case 'no':
        return false;
      default:
        return true;
    }
  }

  final Set<String> _triedPlayers = {};
  String _playerVal;
  String _decodeMode;
  bool _flippedDecodeForCurrent = false;

  String get playerVal => _playerVal;
  String get decodeMode => _decodeMode;

  /// 手动换播放器或新开一集时重置。
  void reset({required String playerVal, required String decodeMode}) {
    _triedPlayers.clear();
    _playerVal = playerVal.trim();
    _decodeMode = normDecode(decodeMode);
    _flippedDecodeForCurrent = false;
  }

  /// 开始用当前播放器尝试（计入已试集合）。
  void markAttempt() {
    if (_playerVal.startsWith('innie#')) {
      _triedPlayers.add(_playerVal);
    }
  }

  /// 开播失败后下一步；`null` 表示放弃。
  KotvFailoverStep? nextStep() {
    if (!enabled) return null;
    if (lockExoForDrm) return null;
    if (!_playerVal.startsWith('innie#')) return null;

    if (!_flippedDecodeForCurrent) {
      final flipped = _flipDecodeForFailover(_decodeMode);
      if (flipped != null) {
        _flippedDecodeForCurrent = true;
        _decodeMode = flipped;
        final label = flipped == 'soft' ? '软解' : '硬解';
        return KotvFailoverStep(
          kind: KotvFailoverKind.flipDecode,
          playerVal: _playerVal,
          decodeMode: flipped,
          status: '无画面，已改$label重试',
        );
      }
    }

    final next = _nextUntriedInnie(_playerVal);
    if (next == null) return null;

    _playerVal = next;
    _decodeMode = settingsDecodeMode;
    _flippedDecodeForCurrent = false;
    _triedPlayers.add(next);
    return KotvFailoverStep(
      kind: KotvFailoverKind.nextPlayer,
      playerVal: next,
      decodeMode: settingsDecodeMode,
      status: '无画面，已切换到${_innieLabel(next)}',
    );
  }

  static String normDecode(String raw) {
    switch (raw.trim().toLowerCase()) {
      case 'soft':
      case 'software':
      case 'sw':
        return 'soft';
      case 'hard':
      case 'hardware':
      case 'hw':
        return 'hard';
      default:
        return 'auto';
    }
  }

  /// auto：协商失败 → 软解；hard/soft：互翻。
  static String? _flipDecodeForFailover(String mode) {
    switch (mode) {
      case 'auto':
        return 'soft';
      case 'hard':
        return 'soft';
      case 'soft':
        return 'hard';
      default:
        return null;
    }
  }

  /// 平台内置播放器环（不含 outie）。
  static List<String> innieRing() {
    if (kIsWeb) {
      return const ['innie#html', 'innie#art', 'innie#xg', 'innie#zw'];
    }
    if (kotvIsAndroid()) {
      // P1 已就绪：Exo（默认/DRM）→ 原生 MPV → FVP。
      return const ['innie#exo', 'innie#mpv', 'innie#fvp'];
    }
    if (kotvIsIOS()) {
      return const ['innie#mpv', 'innie#fvp', 'innie#html'];
    }
    // 桌面（含 Windows）：media_kit MPV + FVP；macOS 可用 KOTV_MACOS_NO_FVP=1 打纯 MPV 包。
    if (Platform.isMacOS && kotvMacosNoFvp) {
      return const ['innie#mpv'];
    }
    return const ['innie#mpv', 'innie#fvp'];
  }

  static String _innieLabel(String playerVal) {
    switch (playerVal.trim()) {
      case 'innie#exo':
        return '内置 ExoPlayer';
      case 'innie#mpv':
        return '内置 MPV';
      case 'innie#fvp':
        return '内置 FVP';
      case 'innie#html':
        return '浏览器 HTML5';
      case 'innie#art':
        return 'ArtPlayer';
      case 'innie#xg':
        return 'xgplayer';
      case 'innie#zw':
        return 'ZWPlayer';
      default:
        return playerVal;
    }
  }

  String? _nextUntriedInnie(String current) {
    final ring = innieRing();
    if (ring.isEmpty) return null;
    var idx = ring.indexOf(current);
    if (idx < 0) idx = -1;
    for (var k = 1; k <= ring.length; k++) {
      final c = ring[(idx + k) % ring.length];
      if (!_triedPlayers.contains(c)) return c;
    }
    return null;
  }
}

enum KotvFailoverKind { flipDecode, nextPlayer }

class KotvFailoverStep {
  const KotvFailoverStep({
    required this.kind,
    required this.playerVal,
    required this.decodeMode,
    required this.status,
  });

  final KotvFailoverKind kind;
  final String playerVal;
  final String decodeMode;
  final String status;
}
