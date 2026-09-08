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

/// 0–9；遥控器数字键 / 键盘主区与小键盘。找不到返回 null。
int? kotvDigitFromKey(LogicalKeyboardKey key) {
  const main = <LogicalKeyboardKey>[
    LogicalKeyboardKey.digit0,
    LogicalKeyboardKey.digit1,
    LogicalKeyboardKey.digit2,
    LogicalKeyboardKey.digit3,
    LogicalKeyboardKey.digit4,
    LogicalKeyboardKey.digit5,
    LogicalKeyboardKey.digit6,
    LogicalKeyboardKey.digit7,
    LogicalKeyboardKey.digit8,
    LogicalKeyboardKey.digit9,
  ];
  const pad = <LogicalKeyboardKey>[
    LogicalKeyboardKey.numpad0,
    LogicalKeyboardKey.numpad1,
    LogicalKeyboardKey.numpad2,
    LogicalKeyboardKey.numpad3,
    LogicalKeyboardKey.numpad4,
    LogicalKeyboardKey.numpad5,
    LogicalKeyboardKey.numpad6,
    LogicalKeyboardKey.numpad7,
    LogicalKeyboardKey.numpad8,
    LogicalKeyboardKey.numpad9,
  ];
  for (var i = 0; i < 10; i++) {
    if (key == main[i] || key == pad[i]) return i;
  }
  return null;
}
