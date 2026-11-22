import 'dart:async' show Completer, unawaited;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'danmaku_layer.dart';
import 'fullscreen_mode.dart';
import 'kotv_platform.dart';
import 'kotv_playback.dart';

/// Win7 原生播控套壳：推送 / 弹层 / 事件的唯一收拢入口。
///
/// 库存引擎下 mpv 子 HWND 盖住 Flutter；本通道驱动 **进程内 GDI+ 子窗**
///（与 `kotv.exe` 同进程）承接播控栏、EPG、弹层与弹幕。
/// 样式与事件契约对齐本应用 Flutter 播控（[VodInlineControls] /
/// [VodFullscreenChrome] / 直播栏）。**Win8+ DComp 不启用本通道**（与 macOS 同为 Flutter chrome）。
class KotvWinChrome {
  KotvWinChrome._();

  static const _ch = MethodChannel('kotv_win_chrome');
  static void Function(Map<String, dynamic> event)? onEvent;
  static bool _handlerBound = false;
  static int _lastDanmakuSig = 0;
  static int _ownerToken = 0;

  /// 与原生壳 / 全屏 HWND inset 同源（逻辑像素）。
  static const double topH = 56;
  static const double bottomH = 128;
  static const double inlineBottomH = 72;
  static const double episodeW = 280;

  static const vodSpeeds = <double>[0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0, 5.0];

  static const videoEqPresets = <(String id, String label)>[
    ('off', '关闭'),
    ('natural', '自然'),
    ('vivid', '鲜艳'),
    ('soft', '柔和'),
    ('cinema', '影院'),
    ('warm', '暖色'),
    ('cool', '冷色'),
    ('anime', '动漫'),
    ('custom', '自定义'),
  ];

  /// 与 Flutter `_showAudioFxSheet` / settings 一致（勿用 music/movie）。
  static const audioEqPresets = <(String id, String label)>[
    ('off', '关闭'),
    ('natural', '自然'),
    ('voice', '人声'),
    ('bass', '低音'),
    ('cinema', '影院'),
    ('custom', '自定义'),
  ];

  static const sleepOptions = <(String id, String label)>[
    ('0', '关闭'),
    ('15', '15 分钟'),
    ('30', '30 分钟'),
    ('45', '45 分钟'),
    ('60', '60 分钟'),
    ('90', '90 分钟'),
  ];

  static const decodeOptions = <(String id, String label)>[
    ('auto', '自动'),
    ('soft', '软解码'),
    ('hard', '硬解码'),
  ];

  static const renderOptions = <(String id, String label)>[
    ('surface', 'Surface（推荐，HDR）'),
    ('texture', 'Texture'),
  ];

  /// 桌面全屏两项：铺满窗口 / 占满屏幕。
  static const fullscreenKindOptions = <(String id, String label)>[
    ('window', '铺满当前窗口'),
    ('display', '占满整块屏幕'),
  ];

  static bool get isNeeded => kotvUsesWindowsNativeChrome();

  static Future<void> showFullscreenKindSheet() => showChoiceSheet(
        kind: 'fullscreenKind',
        title: '全屏',
        options: fullscreenKindOptions,
      );

  /// 弹出原生「铺满窗口 / 占满屏幕」并返回选择；取消或超时返回 null。
  /// 会短暂拦截 [onEvent]，其它事件仍转发给原 handler。
  static Future<KotvDesktopFullscreenKind?> pickFullscreenKind() async {
    if (!isNeeded) return null;
    final c = Completer<KotvDesktopFullscreenKind?>();
    final prev = onEvent;
    late void Function(Map<String, dynamic>) intercept;
    void restore() {
      if (onEvent == intercept) onEvent = prev;
    }

    intercept = (e) {
      final type = e['type'] as String? ?? '';
      final kind = e['kind'] as String? ?? e['sheet'] as String? ?? '';
      if (type == 'sheet' && kind == 'fullscreenKind') {
        final id = e['id'] as String? ?? '';
        if (!c.isCompleted) {
          c.complete(
            id == 'display'
                ? KotvDesktopFullscreenKind.display
                : KotvDesktopFullscreenKind.window,
          );
        }
        restore();
        return;
      }
      if (type == 'sheetClose' && kind == 'fullscreenKind') {
        if (!c.isCompleted) c.complete(null);
        restore();
        prev?.call(e);
        return;
      }
      prev?.call(e);
    };
    onEvent = intercept;
    await showFullscreenKindSheet();
    try {
      return await c.future.timeout(
        const Duration(minutes: 2),
        onTimeout: () {
          restore();
          return null;
        },
      );
    } finally {
      restore();
    }
  }

  // ---------------------------------------------------------------------------
  // 行模型
  // ---------------------------------------------------------------------------

  static Map<String, dynamic> lineItem({
    required String id,
    required String label,
    String trailing = '',
    bool toggle = false,
    bool on = false,
    bool chevron = true,
  }) =>
      {
        'id': id,
        'label': label,
        'trailing': trailing,
        'toggle': toggle,
        'on': on,
        'chevron': !toggle && chevron,
        'slider': false,
      };

  static Map<String, dynamic> sliderItem({
    required String id,
    required String label,
    required double value,
    required double min,
    required double max,
    String trailing = '',
  }) =>
      {
        'id': id,
        'label': label,
        'trailing': trailing.isEmpty ? '${value.round()}' : trailing,
        'toggle': false,
        'on': false,
        'chevron': false,
        'slider': true,
        'value': value,
        'min': min,
        'max': max,
      };

  static List<Map<String, dynamic>> choiceItems(
    List<(String id, String label)> options, {
    String selectedId = '',
  }) =>
      [
        for (final o in options)
          lineItem(
            id: o.$1,
            label: o.$2,
            chevron: false,
            trailing: o.$1 == selectedId ? '✓' : '',
          ),
      ];

  /// 点播「更多」主路径行（含可原生弹层承接的子项入口）。
  static List<Map<String, dynamic>> vodMoreItems({
    required double rate,
    required bool danmakuOn,
    required bool ambientOn,
    required bool repeatOne,
    required bool stableVolume,
    required bool supportsStableVolume,
    required bool loopSkip,
    required int sleepMinutes,
    required String keepLabel,
    required String renderLabel,
    required bool supportsRenderMode,
    required bool canSwitchPlayer,
    required int danmakuSourceCount,
    required String danmakuSourceName,
    bool hasDanmakuSearch = false,
    bool hasCast = false,
    bool hasMini = false,
    bool hasParse = false,
    bool hasKeep = false,
  }) {
    final rateLabel =
        'x${rate.toStringAsFixed(rate == rate.roundToDouble() ? 0 : 1)}';
    final sleepLabel = sleepMinutes <= 0 ? '关闭' : '$sleepMinutes 分钟';
    return [
      lineItem(id: 'videoEq', label: '画面调色'),
      lineItem(id: 'audioFx', label: '音频效果'),
      lineItem(id: 'repeat', label: '循环播放视频', toggle: true, on: repeatOne),
      lineItem(id: 'ambient', label: '氛围模式', toggle: true, on: ambientOn),
      if (supportsStableVolume)
        lineItem(id: 'stableVolume', label: '稳定音量', toggle: true, on: stableVolume),
      lineItem(id: 'loopSkip', label: '跳过片头片尾', toggle: true, on: loopSkip),
      lineItem(id: 'danmakuSettings', label: '弹幕设置'),
      if (danmakuSourceCount > 1)
        lineItem(id: 'danmakuSource', label: '弹幕源', trailing: danmakuSourceName),
      if (hasDanmakuSearch) lineItem(id: 'danmakuSearch', label: '搜索弹幕'),
      lineItem(id: 'sleep', label: '休眠定时器', trailing: sleepLabel),
      if (hasCast) lineItem(id: 'cast', label: '投屏'),
      if (hasMini) lineItem(id: 'mini', label: '迷你桌面播放'),
      if (hasParse) lineItem(id: 'parse', label: '解析'),
      lineItem(id: 'replay', label: '刷新', chevron: false),
      if (hasKeep) lineItem(id: 'keep', label: keepLabel),
      if (supportsRenderMode) lineItem(id: 'render', label: '渲染方式', trailing: renderLabel),
      lineItem(id: 'speed', label: '倍速', trailing: rateLabel),
      if (canSwitchPlayer) lineItem(id: 'player', label: '选播放器'),
      lineItem(id: 'danmaku', label: '弹幕', toggle: true, on: danmakuOn),
      lineItem(id: 'episodes', label: '选集'),
      lineItem(id: 'playInfo', label: '播放信息'),
      lineItem(id: 'exit', label: '退出全屏', chevron: false),
    ];
  }

  /// 详情内嵌「更多」子集（弹幕 + 全屏两项）。
  static List<Map<String, dynamic>> vodInlineMoreItems({
    required bool danmakuOn,
    required int danmakuSourceCount,
    required String danmakuSourceName,
    bool hasDanmakuSearch = true,
  }) =>
      [
        lineItem(id: 'danmaku', label: '弹幕', toggle: true, on: danmakuOn),
        lineItem(id: 'danmakuSettings', label: '弹幕设置'),
        if (danmakuSourceCount > 1)
          lineItem(id: 'danmakuSource', label: '弹幕源', trailing: danmakuSourceName),
        if (hasDanmakuSearch) lineItem(id: 'danmakuSearch', label: '搜索弹幕'),
        lineItem(id: 'expandWindow', label: '铺满当前窗口', chevron: false),
        lineItem(id: 'expandDisplay', label: '占满整块屏幕', chevron: false),
      ];

  /// 弹幕设置：开关 + 主滑条（与 Flutter `danmaku_settings_sheet` 主路径字段对应）。
  static List<Map<String, dynamic>> danmakuSheetItems({
    required bool danmakuOn,
    required bool showScroll,
    required bool showTop,
    required bool showBottom,
    required bool showReverse,
    required bool showPositioned,
    required bool showSpecial,
    required bool bold,
    required double fontSize,
    required double opacity,
    required int rows,
    required int maxOnScreen,
    required double scrollArea,
    required int durationMs,
    required int fixedDurationMs,
  }) =>
      [
        lineItem(id: 'danmaku', label: '开启弹幕', toggle: true, on: danmakuOn),
        lineItem(id: 'danmakuShowScroll', label: '滚动弹幕', toggle: true, on: showScroll),
        lineItem(id: 'danmakuShowTop', label: '顶部弹幕', toggle: true, on: showTop),
        lineItem(id: 'danmakuShowBottom', label: '底部弹幕', toggle: true, on: showBottom),
        lineItem(id: 'danmakuShowReverse', label: '逆向弹幕', toggle: true, on: showReverse),
        lineItem(id: 'danmakuShowPositioned', label: '定位弹幕', toggle: true, on: showPositioned),
        lineItem(id: 'danmakuShowSpecial', label: '特殊弹幕', toggle: true, on: showSpecial),
        lineItem(id: 'danmakuBold', label: '粗体', toggle: true, on: bold),
        sliderItem(
          id: 'danmakuSize',
          label: '字号',
          value: fontSize.clamp(12, 48),
          min: 12,
          max: 48,
        ),
        sliderItem(
          id: 'danmakuOpacity',
          label: '透明度',
          value: (opacity * 100).clamp(15, 100),
          min: 15,
          max: 100,
          trailing: '${(opacity * 100).round()}%',
        ),
        sliderItem(
          id: 'danmakuRows',
          label: '行数',
          value: rows.clamp(1, 16).toDouble(),
          min: 1,
          max: 16,
        ),
        sliderItem(
          id: 'danmakuMaxOnScreen',
          label: '同屏上限',
          value: maxOnScreen.clamp(10, 500).toDouble(),
          min: 10,
          max: 500,
        ),
        sliderItem(
          id: 'danmakuScrollArea',
          label: '滚动区域',
          value: (scrollArea * 100).clamp(10, 100),
          min: 10,
          max: 100,
          trailing: '${(scrollArea * 100).round()}%',
        ),
        sliderItem(
          id: 'danmakuDurationMs',
          label: '滚动时长(秒)',
          value: (durationMs / 1000).clamp(3, 15),
          min: 3,
          max: 15,
        ),
        sliderItem(
          id: 'danmakuFixedDurationMs',
          label: '固定时长(秒)',
          value: (fixedDurationMs / 1000).clamp(2, 10),
          min: 2,
          max: 10,
        ),
      ];

  // ---------------------------------------------------------------------------
  // 通道
  // ---------------------------------------------------------------------------

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
    unawaited(hideSheet());
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

  static Future<void> showSheet({
    required String kind,
    String title = '',
    String subtitle = '',
    required List<Map<String, dynamic>> items,
    int selected = 0,
  }) async {
    if (!isNeeded) return;
    _ensureHandler();
    try {
      await _ch.invokeMethod('showSheet', {
        'kind': kind,
        'title': title,
        'subtitle': subtitle,
        'items': items,
        'selected': selected < 0 ? 0 : selected,
      });
    } catch (_) {}
  }

  static Future<void> hideSheet() async {
    if (!isNeeded) return;
    try {
      await _ch.invokeMethod('hideSheet');
    } catch (_) {}
  }

  static Future<void> showChoiceSheet({
    required String kind,
    required String title,
    required List<(String id, String label)> options,
    String selectedId = '',
    String subtitle = '',
  }) {
    final idx = options.indexWhere((o) => o.$1 == selectedId);
    return showSheet(
      kind: kind,
      title: title,
      subtitle: subtitle,
      items: choiceItems(options, selectedId: selectedId),
      selected: idx < 0 ? 0 : idx,
    );
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

  static String wallClock() {
    final n = DateTime.now();
    return '${n.hour.toString().padLeft(2, '0')}:${n.minute.toString().padLeft(2, '0')}';
  }

  static String endsAtLabel(Duration pos, Duration dur) {
    if (dur.inMilliseconds <= 0) return '';
    final left = dur - pos;
    if (left.inSeconds <= 0) return '';
    final end = DateTime.now().add(left);
    return 'Ends at ${end.hour.toString().padLeft(2, '0')}:${end.minute.toString().padLeft(2, '0')}';
  }

  static double nextSpeed(double cur) {
    var i = vodSpeeds.indexWhere((s) => (s - cur).abs() < 0.01);
    if (i < 0) i = 2;
    return vodSpeeds[(i + 1) % vodSpeeds.length];
  }

  /// 详情非全屏内嵌底栏（契约同 [VodInlineControls]）。
  /// [anchorScreen] / [surfaceScreen]：Flutter 视图逻辑坐标（localToGlobal）。
  static Future<void> pushVodInline({
    required KotvPlayback playback,
    required Map<String, double> anchorScreen,
    Map<String, double>? surfaceScreen,
    required bool chromeVisible,
    bool showDirect = false,
    bool directOn = false,
    bool miniActive = false,
    bool danmakuOn = false,
    /// 解析地址/换集等尚无 player.buffering 时，强制原生壳显示加载态。
    bool forceBuffering = false,
    List<DanmakuItem> danmakuItems = const [],
    List<Map<String, dynamic>>? moreItems,
  }) async {
    if (!isNeeded) return;
    final pos = playback.position;
    final dur = playback.duration;
    final progress = dur.inMilliseconds > 0
        ? (pos.inMilliseconds / dur.inMilliseconds).clamp(0.0, 1.0)
        : 0.0;
    final buffered = dur.inMilliseconds > 0
        ? (playback.buffered.inMilliseconds / dur.inMilliseconds).clamp(0.0, 1.0)
        : 0.0;
    await update({
      'mode': 'vod_inline',
      'anchorScreen': anchorScreen,
      if (surfaceScreen != null) 'surfaceScreen': surfaceScreen,
      'positionLabel': formatClock(pos),
      'durationLabel': formatClock(dur),
      'progress': progress,
      'buffered': buffered,
      'positionSec': pos.inMilliseconds / 1000.0,
      'rate': playback.rate,
      'playing': playback.playing,
      'buffering': forceBuffering || playback.buffering || playback.stalling,
      'volume': playback.volume.clamp(0, 100),
      'showDirect': showDirect,
      'directOn': directOn,
      'miniActive': miniActive,
      'top': false,
      'bottom': chromeVisible,
      'episodesVisible': false,
      'centerVisible': false,
      'liveLeftVisible': false,
      'liveRightVisible': false,
      'channelVisible': false,
      'actions': const ['toggle', 'stop', 'cast', 'mini', 'expand'],
      if (moreItems != null) 'moreItems': moreItems,
    });
    await setDanmaku(enabled: danmakuOn, items: danmakuItems);
  }

  /// 点播全屏快照。
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
    String resolution = '',
    List<Map<String, dynamic>>? moreItems,
    double danmakuFontSize = 18,
    double danmakuOpacity = 0.85,
    int danmakuDurationMs = 8000,
    int danmakuFixedDurationMs = 5000,
    int danmakuRows = 6,
    bool danmakuShowScroll = true,
    bool danmakuShowTop = true,
    bool danmakuShowBottom = true,
    bool danmakuShowReverse = true,
    int openingSec = 0,
    int endingSec = 0,
    String aspect = 'default',
    String decodeMode = 'auto',
    bool showDirect = false,
    bool directOn = false,
    bool forceBuffering = false,
  }) async {
    if (!isNeeded) return;
    final pos = playback.position;
    final dur = playback.duration;
    final progress = dur.inMilliseconds > 0
        ? (pos.inMilliseconds / dur.inMilliseconds).clamp(0.0, 1.0)
        : 0.0;
    final w = playback.width;
    final h = playback.height;
    final res = resolution.isNotEmpty
        ? resolution
        : (w > 0 && h > 0 ? '$w x $h' : '');
    await update({
      'mode': 'vod',
      'title': title,
      'subtitle': subtitle,
      if (res.isNotEmpty) 'resolution': res,
      'clock': wallClock(),
      'endsAt': endsAtLabel(pos, dur),
      'positionLabel': formatClock(pos),
      'durationLabel': formatClock(dur),
      'episodes': episodes,
      'episodeSelected': episodeSelected,
      'progress': progress,
      'positionSec': pos.inMilliseconds / 1000.0,
      'rate': playback.rate,
      'playing': playback.playing,
      'buffering': forceBuffering || playback.buffering || playback.stalling,
      'volume': playback.volume.clamp(0, 100),
      'openingSec': openingSec,
      'endingSec': endingSec,
      'aspect': aspect,
      'decode': decodeMode,
      'showDirect': showDirect,
      'directOn': directOn,
      'top': chromeVisible,
      'bottom': chromeVisible,
      'episodesVisible': episodesVisible,
      'centerVisible': chromeVisible && !episodesVisible,
      'liveLeftVisible': false,
      'liveRightVisible': false,
      'channelVisible': false,
      'actions': const [
        'prev',
        'toggle',
        'next',
        'speed',
        'replay',
        'aspect',
        'decode',
        'subtitle',
        'audio',
        'video',
        'player',
        'more',
        'episodes',
      ],
      if (moreItems != null) 'moreItems': moreItems,
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

  /// 直播快照。
  static Future<void> pushLive({
    required KotvPlayback playback,
    required String title,
    required String channelText,
    required List<String> liveLeft,
    required int liveLeftSelected,
    required List<Map<String, dynamic>> liveRightItems,
    required bool leftOpen,
    required bool rightOpen,
    required bool channelVisible,
    required List<DanmakuItem> danmakuItems,
    List<String>? groups,
    int groupSelected = -1,
    List<String>? channels,
    int channelSelected = -1,
    List<String>? epgDays,
    int epgDaySelected = 0,
    List<String>? epgPrograms,
    int epgProgramSelected = -1,
    bool epgOpen = true,
    String channelNo = '',
    String channelName = '',
    String channelProgram = '',
    String channelTicker = '',
    bool danmakuEnabled = true,
  }) async {
    if (!isNeeded) return;
    final pos = playback.position;
    final dur = playback.duration;
    final rightLabels = [
      for (final a in liveRightItems) '${a['label'] ?? ''}',
    ];
    await update({
      'mode': 'live',
      'title': title,
      'channelText': channelText,
      if (channelNo.isNotEmpty) 'channelNo': channelNo,
      if (channelName.isNotEmpty) 'channelName': channelName,
      if (channelProgram.isNotEmpty) 'channelProgram': channelProgram,
      if (channelTicker.isNotEmpty) 'channelTicker': channelTicker,
      'liveLeft': liveLeft,
      'liveLeftSelected': liveLeftSelected,
      'liveRight': rightLabels,
      'liveRightItems': liveRightItems,
      if (groups != null) 'groups': groups,
      'groupSelected': groupSelected,
      if (channels != null) 'channels': channels,
      'channelSelected': channelSelected >= 0 ? channelSelected : liveLeftSelected,
      if (epgDays != null) 'epgDays': epgDays,
      'epgDaySelected': epgDaySelected,
      if (epgPrograms != null) 'epgPrograms': epgPrograms,
      'epgProgramSelected': epgProgramSelected,
      'epgOpen': epgOpen,
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
      showScroll,
      showTop,
      showBottom,
      showReverse,
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

  // ---------------------------------------------------------------------------
  // 弹层收拢（屏幕层只调这些，勿再手搓 showSheet 参数表）
  // ---------------------------------------------------------------------------

  static Future<void> showDanmakuSettingsSheet({
    required bool danmakuOn,
    required bool showScroll,
    required bool showTop,
    required bool showBottom,
    required bool showReverse,
    required bool showPositioned,
    required bool showSpecial,
    required bool bold,
    required double fontSize,
    required double opacity,
    required int rows,
    required int maxOnScreen,
    required double scrollArea,
    required int durationMs,
    required int fixedDurationMs,
  }) =>
      showSheet(
        kind: 'danmaku',
        title: '弹幕设置',
        items: danmakuSheetItems(
          danmakuOn: danmakuOn,
          showScroll: showScroll,
          showTop: showTop,
          showBottom: showBottom,
          showReverse: showReverse,
          showPositioned: showPositioned,
          showSpecial: showSpecial,
          bold: bold,
          fontSize: fontSize,
          opacity: opacity,
          rows: rows,
          maxOnScreen: maxOnScreen,
          scrollArea: scrollArea,
          durationMs: durationMs,
          fixedDurationMs: fixedDurationMs,
        ),
      );

  static Future<void> showPlayerPickerSheet({
    required String currentId,
    required List<(String label, String id)> options,
    String title = '请选择播放器',
    String? subtitle,
  }) {
    final cur = currentId;
    final idx = options.indexWhere((o) => o.$2 == cur);
    return showSheet(
      kind: 'player',
      title: title,
      subtitle: subtitle ?? (cur.isEmpty ? '' : '当前：$cur'),
      items: [
        for (final o in options)
          lineItem(
            id: o.$2,
            label: o.$1,
            chevron: false,
            trailing: o.$2 == cur ? '✓' : '',
          ),
      ],
      selected: idx < 0 ? 0 : idx,
    );
  }

  static Future<void> showVolumeSheet(double volume) => showSheet(
        kind: 'volume',
        title: '音量',
        items: [
          sliderItem(
            id: 'volume',
            label: '音量',
            value: volume.clamp(1, 100),
            min: 1,
            max: 100,
          ),
        ],
      );

  static Future<void> showRenderSheet(String selectedId) => showChoiceSheet(
        kind: 'render',
        title: '渲染方式',
        options: renderOptions,
        selectedId: selectedId,
      );

  static Future<void> showDecodeSheet(String selectedId) => showChoiceSheet(
        kind: 'decode',
        title: '解码方式',
        options: decodeOptions,
        selectedId: selectedId,
      );

  /// 弹幕设置项 persist：返回是否已处理。屏幕层在 true 时再 notify / sync。
  static Future<bool> persistDanmakuToggle({
    required String id,
    required bool on,
    required Future<void> Function(String key, String value) persist,
  }) async {
    switch (id) {
      case 'danmaku':
      case 'danmakuShowScroll':
      case 'danmakuShowTop':
      case 'danmakuShowBottom':
      case 'danmakuShowReverse':
      case 'danmakuShowPositioned':
      case 'danmakuShowSpecial':
      case 'danmakuBold':
        await persist(id == 'danmaku' ? 'danmaku' : id, on ? 'true' : 'false');
        return true;
      default:
        return false;
    }
  }

  /// 弹幕滑条 commit persist：返回是否已处理。
  static Future<bool> persistDanmakuSlider({
    required String id,
    required double value,
    required Future<void> Function(String key, String value) persist,
  }) async {
    switch (id) {
      case 'danmakuSize':
        await persist(id, '${value.round()}');
        return true;
      case 'danmakuOpacity':
        await persist(id, (value / 100).toStringAsFixed(2));
        return true;
      case 'danmakuRows':
      case 'danmakuMaxOnScreen':
        await persist(id, '${value.round()}');
        return true;
      case 'danmakuScrollArea':
        await persist(id, (value / 100).toStringAsFixed(2));
        return true;
      case 'danmakuDurationMs':
      case 'danmakuFixedDurationMs':
        await persist(id, '${(value * 1000).round()}');
        return true;
      default:
        return false;
    }
  }

  /// 原生壳 `key.logical` 名称 → Flutter [LogicalKeyboardKey]。
  static LogicalKeyboardKey? logicalKeyFromName(String name) {
    switch (name) {
      case 'Escape':
        return LogicalKeyboardKey.escape;
      case 'Enter':
        return LogicalKeyboardKey.enter;
      case 'Space':
        return LogicalKeyboardKey.space;
      case 'ArrowLeft':
        return LogicalKeyboardKey.arrowLeft;
      case 'ArrowRight':
        return LogicalKeyboardKey.arrowRight;
      case 'ArrowUp':
        return LogicalKeyboardKey.arrowUp;
      case 'ArrowDown':
        return LogicalKeyboardKey.arrowDown;
      case 'PageUp':
        return LogicalKeyboardKey.pageUp;
      case 'PageDown':
        return LogicalKeyboardKey.pageDown;
      case 'ContextMenu':
        return LogicalKeyboardKey.contextMenu;
      case 'GoBack':
        return LogicalKeyboardKey.goBack;
      case 'MediaPlayPause':
        return LogicalKeyboardKey.mediaPlayPause;
      case 'MediaRewind':
        return LogicalKeyboardKey.mediaRewind;
      case 'MediaFastForward':
        return LogicalKeyboardKey.mediaFastForward;
      case 'MediaTrackPrevious':
        return LogicalKeyboardKey.mediaTrackPrevious;
      case 'MediaTrackNext':
        return LogicalKeyboardKey.mediaTrackNext;
      case 'VolumeUp':
        return LogicalKeyboardKey.audioVolumeUp;
      case 'VolumeDown':
        return LogicalKeyboardKey.audioVolumeDown;
      case 'VolumeMute':
        return LogicalKeyboardKey.audioVolumeMute;
      case 'KeyE':
        return LogicalKeyboardKey.keyE;
      case 'KeyM':
        return LogicalKeyboardKey.keyM;
      case 'KeyS':
        return LogicalKeyboardKey.keyS;
      default:
        if (name.startsWith('Digit') && name.length == 6) {
          const digits = <LogicalKeyboardKey>[
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
          final d = int.tryParse(name.substring(5));
          if (d != null && d >= 0 && d <= 9) return digits[d];
        }
        return null;
    }
  }

  /// 由原生壳 key 事件构造 Flutter [KeyEvent]（供复用 `_onKey`）。
  static KeyEvent? keyEventFromMap(Map<String, dynamic> e) {
    final logical = logicalKeyFromName(e['logical'] as String? ?? '');
    if (logical == null) return null;
    final time = Duration.zero;
    final physical = PhysicalKeyboardKey(logical.keyId & 0xFFFFFFFF);
    if (e['up'] == true) {
      return KeyUpEvent(physicalKey: physical, logicalKey: logical, timeStamp: time);
    }
    if (e['repeat'] == true) {
      return KeyRepeatEvent(physicalKey: physical, logicalKey: logical, timeStamp: time);
    }
    return KeyDownEvent(physicalKey: physical, logicalKey: logical, timeStamp: time);
  }
}
