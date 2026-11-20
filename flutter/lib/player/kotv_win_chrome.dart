import 'dart:async' show unawaited;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'danmaku_layer.dart';
import 'kotv_platform.dart';
import 'kotv_playback.dart';

/// Win7 原生套壳通道与推送收拢。
///
/// 库存引擎下子 HWND 盖住 Flutter，用原生层承接点播全屏/直播菜单/弹幕/缓冲。
/// 不是 Flutter 全屏播控的完整复刻（无「更多」sheet、轨表编辑等）；常用动作在壳上。
/// Win8+ DComp 路径不使用本通道。
class KotvWinChrome {
  KotvWinChrome._();

  static const _ch = MethodChannel('kotv_win_chrome');
  static void Function(Map<String, dynamic> event)? onEvent;
  static bool _handlerBound = false;
  static int _lastDanmakuSig = 0;
  static int _ownerToken = 0;

  static bool get isNeeded => kotvUsesWindowsNativeChrome();

  static void _ensureHandler() {
    if (_handlerBound || kIsWeb) return;
    _handlerBound = true;
    _ch.setMethodCallHandler((call) async {
      if (call.method == 'event') {
        final args = call.arguments;
        if (args is Map) {
          onEvent?.call(Map<String, dynamic>.from(args));
        }
      }
      return null;
    });
  }

  /// 绑定事件与启用原生层；返回 token，解绑时校验避免串页。
  static int bind(void Function(Map<String, dynamic>) handler) {
    if (!isNeeded) return 0;
    _ensureHandler();
    final token = ++_ownerToken;
    onEvent = handler;
    unawaited(setEnabled(true));
    return token;
  }

  static void unbind(int token) {
    if (!isNeeded) return;
    if (token != 0 && token != _ownerToken) return;
    onEvent = null;
    _lastDanmakuSig = 0;
    unawaited(setEnabled(false));
  }

  static Future<void> setEnabled(bool enabled) async {
    if (!isNeeded) return;
    _ensureHandler();
    try {
      await _ch.invokeMethod('setEnabled', {'enabled': enabled});
      if (!enabled) _lastDanmakuSig = 0;
    } catch (_) {}
  }

  static Future<void> update(Map<String, dynamic> fields) async {
    if (!isNeeded) return;
    _ensureHandler();
    try {
      await _ch.invokeMethod('update', fields);
    } catch (_) {}
  }

  static Future<void> layout() async {
    if (!isNeeded) return;
    try {
      await _ch.invokeMethod('layout');
    } catch (_) {}
  }

  static String formatClock(Duration d) {
    if (d.inMilliseconds <= 0) return '--:--';
    final s = d.inSeconds;
    final m = s ~/ 60;
    final r = s % 60;
    final h = m ~/ 60;
    if (h > 0) {
      return '$h:${(m % 60).toString().padLeft(2, '0')}:${r.toString().padLeft(2, '0')}';
    }
    return '${m.toString().padLeft(2, '0')}:${r.toString().padLeft(2, '0')}';
  }

  /// 点播全屏快照（顶/底/选集/中心/弹幕）。
  static Future<void> pushVod({
    required KotvPlayback playback,
    required String title,
    required String subtitle,
    required List<String> episodes,
    required int episodeSelected,
    required bool chromeVisible,
    required bool episodesVisible,
    required bool danmakuOn,
    required List<DanmakuItem> danmakuItems,
    double danmakuFontSize = 18,
    double danmakuOpacity = 0.85,
    int danmakuDurationMs = 8000,
    int danmakuFixedDurationMs = 5000,
    int danmakuRows = 6,
    bool danmakuShowScroll = true,
    bool danmakuShowTop = true,
    bool danmakuShowBottom = true,
    bool danmakuShowReverse = true,
  }) async {
    if (!isNeeded) return;
    final pos = playback.position;
    final dur = playback.duration;
    final progress = dur.inMilliseconds > 0
        ? (pos.inMilliseconds / dur.inMilliseconds).clamp(0.0, 1.0)
        : 0.0;
    final rate = playback.rate;
    final rateLabel =
        'x${rate.toStringAsFixed(rate == rate.roundToDouble() ? 0 : 1)}';
    await update({
      'mode': 'vod',
      'title': title,
      'subtitle': subtitle,
      'bottomText': '${formatClock(pos)} / ${formatClock(dur)} · $rateLabel',
      'episodes': episodes,
      'episodeSelected': episodeSelected,
      'progress': progress,
      'positionSec': pos.inMilliseconds / 1000.0,
      'rate': rate,
      'playing': playback.playing,
      'buffering': playback.buffering || playback.stalling,
      'top': chromeVisible,
      'bottom': chromeVisible,
      'episodesVisible': episodesVisible,
      'centerVisible': chromeVisible && !episodesVisible,
      'liveLeftVisible': false,
      'liveRightVisible': false,
      'channelVisible': false,
      'actions': const ['prev', 'toggle', 'next', 'speed', 'replay', 'episodes'],
    });
    await setDanmaku(
      enabled: danmakuOn,
      items: danmakuItems,
      fontSize: danmakuFontSize,
      opacity: danmakuOpacity,
      durationMs: danmakuDurationMs,
      fixedDurationMs: danmakuFixedDurationMs,
      rows: danmakuRows,
      showScroll: danmakuShowScroll,
      showTop: danmakuShowTop,
      showBottom: danmakuShowBottom,
      showReverse: danmakuShowReverse,
    );
  }

  /// 直播快照（左频道/右设置/频道条/弹幕）。
  static Future<void> pushLive({
    required KotvPlayback playback,
    required String title,
    required String channelText,
    required List<String> liveLeft,
    required int liveLeftSelected,
    required List<String> liveRight,
    required bool leftOpen,
    required bool rightOpen,
    required bool channelVisible,
    required List<DanmakuItem> danmakuItems,
    bool danmakuEnabled = true,
  }) async {
    if (!isNeeded) return;
    final pos = playback.position;
    final dur = playback.duration;
    await update({
      'mode': 'live',
      'title': title,
      'channelText': channelText,
      'liveLeft': liveLeft,
      'liveLeftSelected': liveLeftSelected,
      'liveRight': liveRight,
      'playing': playback.playing,
      'buffering': playback.buffering || playback.stalling,
      'positionSec': pos.inMilliseconds / 1000.0,
      'progress': dur.inMilliseconds > 0
          ? (pos.inMilliseconds / dur.inMilliseconds).clamp(0.0, 1.0)
          : 0.0,
      'rate': playback.rate,
      'top': false,
      'bottom': false,
      'episodesVisible': false,
      'centerVisible': false,
      'liveLeftVisible': leftOpen,
      'liveRightVisible': rightOpen,
      'channelVisible': channelVisible,
      'actions': const <String>[],
    });
    await setDanmaku(enabled: danmakuEnabled, items: danmakuItems);
  }

  static Future<void> setDanmaku({
    required bool enabled,
    required List<DanmakuItem> items,
    double fontSize = 18,
    double opacity = 0.85,
    int durationMs = 8000,
    int fixedDurationMs = 5000,
    int rows = 6,
    bool showScroll = true,
    bool showTop = true,
    bool showBottom = true,
    bool showReverse = true,
  }) async {
    if (!isNeeded) return;
    _ensureHandler();
    final sig = Object.hash(
      items.length,
      items.isEmpty ? 0 : items.first.time,
      items.isEmpty ? 0 : items.last.time,
      items.isEmpty ? 0 : items.first.content.hashCode,
      enabled,
      fontSize,
      rows,
    );
    final itemsChanged = sig != _lastDanmakuSig;
    _lastDanmakuSig = sig;
    try {
      final map = <String, dynamic>{
        'enabled': enabled,
        'fontSize': fontSize,
        'opacity': opacity,
        'durationMs': durationMs,
        'fixedDurationMs': fixedDurationMs,
        'rows': rows,
        'showScroll': showScroll,
        'showTop': showTop,
        'showBottom': showBottom,
        'showReverse': showReverse,
      };
      if (itemsChanged) {
        const maxItems = 4000;
        final src = items.length > maxItems
            ? items.sublist(items.length - maxItems)
            : items;
        map['items'] = [
          for (final it in src)
            {
              't': it.time,
              'c': it.content,
              'm': it.mode,
              'color': it.color,
              'size': it.size,
            },
        ];
      }
      await _ch.invokeMethod('setDanmaku', map);
    } catch (_) {}
  }
}
