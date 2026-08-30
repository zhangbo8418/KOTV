import 'package:flutter/services.dart';

/// 对齐 FongMi TV [KeyUtil] 的遥控键判定（点播/直播共用）。
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

bool kotvIsBackKey(LogicalKeyboardKey key) =>
    key == LogicalKeyboardKey.escape || key == LogicalKeyboardKey.goBack;

bool kotvIsMediaPlayPause(LogicalKeyboardKey key) =>
    key == LogicalKeyboardKey.mediaPlayPause ||
    key == LogicalKeyboardKey.mediaPlay ||
    key == LogicalKeyboardKey.mediaPause;

bool kotvIsMediaRewind(LogicalKeyboardKey key) => key == LogicalKeyboardKey.mediaRewind;

bool kotvIsMediaFastForward(LogicalKeyboardKey key) =>
    key == LogicalKeyboardKey.mediaFastForward;
