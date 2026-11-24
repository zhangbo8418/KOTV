import 'package:flutter/foundation.dart' show kIsWeb;

import '../util/kotv_io.dart';
import 'kotv_platform.dart';
import 'player_normalize.dart';

/// 开播黑屏/超时后的会话内回退（各平台同一套，不写死某一引擎）：
/// 1. 当前不是软解 → 显式软解再试（自动档由引擎内部自选；挂死无 error 时须靠这一步）。
/// 2. 已是软解 → 按 [innieRing] 换下一个内置播放器，并恢复用户设置的解码。
/// 不写回设置里的 `player` / `playerLive` / `playerDecode`。
class KotvPlaybackFailover {
  KotvPlaybackFailover({
    required String playerVal,
    required String decodeMode,
    /// 用户偏好解码；换引擎时恢复。默认与 [decodeMode] 相同。
    /// 会话内临时 soft 重试时须显式传入偏好，避免把 soft 当成设置。
    String? settingsDecodeMode,
    this.lockExoForDrm = false,
    this.enabled = true,
  })  : settingsDecodeMode = normDecode(settingsDecodeMode ?? decodeMode),
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

  String get playerVal => _playerVal;
  String get decodeMode => _decodeMode;

  /// 手动换播放器或新开一集时重置。
  void reset({required String playerVal, required String decodeMode}) {
    _triedPlayers.clear();
    _playerVal = playerVal.trim();
    _decodeMode = normDecode(decodeMode);
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

    // 自动 = 引擎内部自选；无画面时显式软解。Apple underlay 软解 DV 易黑帧，跳过。
    if (_decodeMode != 'soft' && !kotvIsApple()) {
      final from = _decodeMode;
      _decodeMode = 'soft';
      return KotvFailoverStep(
        kind: KotvFailoverKind.softDecode,
        playerVal: _playerVal,
        decodeMode: _decodeMode,
        status: from == 'hard' ? '硬解无画面，已改软解码重试' : '自动解码无画面，已改软解码重试',
      );
    }

    final next = _nextUntriedInnie(_playerVal);
    if (next == null) return null;

    _playerVal = next;
    _decodeMode = settingsDecodeMode;
    _triedPlayers.add(next);
    return KotvFailoverStep(
      kind: KotvFailoverKind.nextPlayer,
      playerVal: next,
      decodeMode: settingsDecodeMode,
      status: '无画面，已切换到${_innieLabel(next)}',
    );
  }

  static String normDecode(String raw) => kotvNormalizeDecodeMode(raw);

  /// 平台内置播放器环（不含 outie）。
  static List<String> innieRing() {
    if (kIsWeb) {
      return const ['innie#html', 'innie#art', 'innie#xg', 'innie#zw'];
    }
    if (kotvIsAndroid()) {
      // 安卓：Exo + 原生 MPV（无 FVP）。
      return const ['innie#exo', 'innie#mpv'];
    }
    if (kotvIsIOS()) {
      return const ['innie#html', 'innie#mpv', 'innie#fvp'];
    }
    // 桌面：原生 MPV + FVP；macOS 可用 KOTV_MACOS_NO_FVP=1 打纯 MPV 包。
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
        return kotvHtmlPlayerLabel();
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

enum KotvFailoverKind { softDecode, nextPlayer }

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

/// 起播无画面后的恢复动作（决策集中在此，页面只负责拆机/换引擎）。
enum KotvSilentRecoverAction {
  /// 采用 [KotvSilentRecover.step] 换解码或换播放器。
  applyStep,

  /// 关闭自动切换：保留当前会话，不判失败。
  keepSession,

  /// 自动切换开着但已无下一档：放弃。
  giveUp,
}

class KotvSilentRecover {
  const KotvSilentRecover(this.action, {this.step});

  final KotvSilentRecoverAction action;
  final KotvFailoverStep? step;
}

/// 无画面后的恢复策略。若返回 [KotvSilentRecoverAction.applyStep]，
/// [failover.nextStep] 已写入新的 player/decode。
KotvSilentRecover kotvPlanSilentRecover({required KotvPlaybackFailover failover}) {
  if (!failover.enabled) {
    return const KotvSilentRecover(KotvSilentRecoverAction.keepSession);
  }
  final step = failover.nextStep();
  if (step != null) {
    return KotvSilentRecover(KotvSilentRecoverAction.applyStep, step: step);
  }
  return const KotvSilentRecover(KotvSilentRecoverAction.giveUp);
}
