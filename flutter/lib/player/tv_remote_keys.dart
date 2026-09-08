import 'dart:async';

import 'package:flutter/services.dart';

/// 遥控键判定（点播/直播共用）。
bool kotvIsEnterKey(LogicalKeyboardKey key) =>
    key == LogicalKeyboardKey.select ||
    key == LogicalKeyboardKey.enter ||
    key == LogicalKeyboardKey.numpadEnter ||
    key == LogicalKeyboardKey.space;

bool kotvIsUpKey(LogicalKeyboardKey key) =>
    key == LogicalKeyboardKey.arrowUp ||
    key == LogicalKeyboardKey.channelUp ||
    key == LogicalKeyboardKey.pageUp ||
    key == LogicalKeyboardKey.mediaTrackPrevious;

bool kotvIsDownKey(LogicalKeyboardKey key) =>
    key == LogicalKeyboardKey.arrowDown ||
    key == LogicalKeyboardKey.channelDown ||
    key == LogicalKeyboardKey.pageDown ||
    key == LogicalKeyboardKey.mediaTrackNext;

bool kotvIsLeftKey(LogicalKeyboardKey key) => key == LogicalKeyboardKey.arrowLeft;

bool kotvIsRightKey(LogicalKeyboardKey key) => key == LogicalKeyboardKey.arrowRight;

bool kotvIsMenuKey(LogicalKeyboardKey key) =>
    key == LogicalKeyboardKey.contextMenu || key == LogicalKeyboardKey.keyM;

/// 设置键 / 菜单长按：点播右侧选集、直播右侧设置。
bool kotvIsSettingsKey(LogicalKeyboardKey key) =>
    key == LogicalKeyboardKey.settings || key == LogicalKeyboardKey.keyS;

bool kotvIsBackKey(LogicalKeyboardKey key) =>
    key == LogicalKeyboardKey.escape || key == LogicalKeyboardKey.goBack;

bool kotvIsMediaPlayPause(LogicalKeyboardKey key) =>
    key == LogicalKeyboardKey.mediaPlayPause ||
    key == LogicalKeyboardKey.mediaPlay ||
    key == LogicalKeyboardKey.mediaPause;

bool kotvIsMediaRewind(LogicalKeyboardKey key) => key == LogicalKeyboardKey.mediaRewind;

bool kotvIsMediaFastForward(LogicalKeyboardKey key) =>
    key == LogicalKeyboardKey.mediaFastForward;

/// 菜单短按 / 长按（≥400ms）：短按底栏，长按右侧面板。
class KotvMenuKeyGate {
  Timer? _longTimer;
  bool _armed = false;
  bool _longFired = false;
  static const longPress = Duration(milliseconds: 400);

  /// 返回 true 表示已消费。
  bool onEvent(
    KeyEvent event, {
    required void Function() onShort,
    required void Function() onLong,
  }) {
    final key = event.logicalKey;
    if (!kotvIsMenuKey(key)) return false;
    if (event is KeyDownEvent) {
      if (_armed) return true; // 忽略长按连发
      _armed = true;
      _longFired = false;
      _longTimer?.cancel();
      _longTimer = Timer(longPress, () {
        _longFired = true;
        onLong();
      });
      return true;
    }
    if (event is KeyUpEvent) {
      _longTimer?.cancel();
      _longTimer = null;
      if (_armed && !_longFired) onShort();
      _armed = false;
      _longFired = false;
      return true;
    }
    return false;
  }

  void reset() {
    _longTimer?.cancel();
    _longTimer = null;
    _armed = false;
    _longFired = false;
  }
}
