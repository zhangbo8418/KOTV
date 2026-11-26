import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/kotv_palette.dart';
import '../theme/layout_scale.dart';
import '../widgets/kotv_network_image.dart';
import 'danmaku_layer.dart';
import 'kotv_platform.dart';
import 'kotv_playback.dart';
import 'kotv_traffic.dart';

/// Win7 原生播控通道：推送 / 弹层 / 事件的唯一收拢入口。
///
/// mpv 子 HWND 盖住 Flutter；由进程内分层窗口（`win7_chrome_*.cpp`）绘制播控、
/// 直播面板、弹层、HUD 与弹幕。样式与操作逻辑以 Flutter 播控为准
///（[VodInlineControls] / [VodFullscreenChrome] / 直播面板 / LiveCatchupChrome / MiniHoverShell）。
/// 画面区指针事件经 [pointerEvent] 还原成 Flutter [PointerEvent]，页面复用自己的手势处理。
/// **仅 Win7 启用**；其它平台仍用 Flutter 播控。
class KotvWinChrome {
  KotvWinChrome._();

  static const _ch = MethodChannel('kotv_win_chrome');
  static void Function(Map<String, dynamic> event)? onEvent;
  static bool _handlerBound = false;
  static int _lastDanmakuSig = 0;
  static int _ownerToken = 0;

  static bool get isNeeded => kotvUsesWindowsNativeChrome();

  /// 详情内嵌底栏高度（与原生 VodInlineControls 同式：上下内边距 + 按钮 + 进度条）。
  static double inlineBarHeight(BuildContext context, double width) {
    final ui = LayoutScale.grow(context);
    final narrow = width < 480;
    return ((narrow ? 2.0 : 6.0) * 2 + (narrow ? 32.0 : 40.0) + 24) * ui;
  }

  // ---------------------------------------------------------------------------
  // 与 Flutter 播控同源的选项表
  // ---------------------------------------------------------------------------

  static const vodSpeeds = <double>[0.5, 0.75, 1.0, 1.25, 1.5, 2.0, 3.0, 5.0];

  /// key / 标签 / 角标（[VodFullscreenChrome] `_aspects` / `_aspectBadge`）。
  static const aspects = <(String key, String label, String badge)>[
    ('default', '适应', '适'),
    ('fill', '拉伸', '拉'),
    ('zoom', 'Zoom', 'Z'),
    ('16:9', '16:9', '16'),
    ('4:3', '4:3', '4'),
  ];

  static const decodeModes = <(String key, String label)>[
    ('auto', '自动'),
    ('soft', '软解码'),
    ('hard', '硬解码'),
  ];

  static const renderModes = <(String key, String label)>[
    ('surface', 'Surface（推荐，HDR）'),
    ('texture', 'Texture'),
  ];

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
  ];

  static String rateBadge(double r) => 'x${r.toStringAsFixed(r == r.roundToDouble() ? 0 : 1)}';

  static String aspectBadge(String key) =>
      aspects.firstWhere((a) => a.$1 == key, orElse: () => aspects.first).$3;

  static String decodeBadge(String mode) =>
      decodeModes.firstWhere((d) => d.$1 == mode, orElse: () => decodeModes.first).$2.substring(0, 1);

  static double nextSpeed(double cur) {
    var i = vodSpeeds.indexWhere((s) => (s - cur).abs() < 0.01);
    if (i < 0) i = 1;
    return vodSpeeds[(i + 1) % vodSpeeds.length];
  }

  static String nextAspect(String key) {
    final i = aspects.indexWhere((a) => a.$1 == key);
    return aspects[(i + 1) % aspects.length].$1;
  }

  static String nextDecode(String mode) {
    final i = decodeModes.indexWhere((d) => d.$1 == mode);
    return decodeModes[(i + 1) % decodeModes.length].$1;
  }

  // ---------------------------------------------------------------------------
  // 行模型（原生 `LineItem`）
  // ---------------------------------------------------------------------------

  /// [kind]：select（默认，选中打勾）/ link / cycle / toggle / switch / header / info / text /
  /// chip / action / big / slider / sliderInline / hold / button；直播：title / pill / label / gap。
  static Map<String, dynamic> row({
    String id = '',
    required String label,
    String kind = 'select',
    String trailing = '',
    String icon = '',
    String sub = '',
    bool selected = false,
    bool on = false,
    bool chevron = false,
    double? value,
    double min = 0,
    double max = 100,
    int divisions = 0,
  }) =>
      {
        'id': id,
        'label': label,
        'kind': kind,
        if (trailing.isNotEmpty) 'trailing': trailing,
        if (icon.isNotEmpty) 'icon': icon,
        if (sub.isNotEmpty) 'sub': sub,
        'selected': selected,
        'on': on,
        'chevron': chevron,
        if (value != null) 'value': value,
        'min': min,
        'max': max,
        if (divisions > 0) 'divisions': divisions,
      };

  /// [KotvStepSlider] 行；[format] 为 printf（%f 系）格式，原生拖动时就地刷新数值。
  static Map<String, dynamic> slider({
    required String id,
    required String label,
    required double value,
    required double min,
    required double max,
    required int divisions,
    String format = '%.0f',
    bool inline = false,
  }) {
    final v = value.clamp(min, max).toDouble();
    return row(
      id: id,
      label: label,
      kind: inline ? 'sliderInline' : 'slider',
      value: v,
      min: min,
      max: max,
      divisions: divisions,
      sub: format,
      trailing: _cFormat(format, v),
    );
  }

  static String _cFormat(String fmt, double v) {
    final m = RegExp(r'%(\+?)\.(\d)f').firstMatch(fmt);
    if (m == null) return fmt.replaceAll('%%', '%');
    var num = v.toStringAsFixed(int.parse(m.group(2)!));
    if (m.group(1) == '+' && v >= 0) num = '+$num';
    return fmt.replaceRange(m.start, m.end, num).replaceAll('%%', '%');
  }

  static List<Map<String, dynamic>> choiceRows(
    List<(String id, String label)> options, {
    String selectedId = '',
    String icon = '',
  }) =>
      [
        for (final o in options) row(id: o.$1, label: o.$2, icon: icon, selected: o.$1 == selectedId),
      ];

  // ---------------------------------------------------------------------------
  // 公共推送字段
  // ---------------------------------------------------------------------------

  // ignore: deprecated_member_use
  static int _argb(Color c) => c.value;

  /// DPI、LayoutScale、文字缩放与调色板（原生尺寸/颜色同 Flutter）。
  static Map<String, dynamic> metrics(BuildContext context) {
    final p = KotvPalette.of(context);
    return {
      'dpr': MediaQuery.devicePixelRatioOf(context),
      'uiScale': LayoutScale.of(context),
      'textScale': MediaQuery.textScalerOf(context).scale(1.0),
      'palPrimary': _argb(p.primary),
      'palFg': _argb(p.fg),
      'palMuted': _argb(p.muted),
      'palPillBg': _argb(p.pillBg),
      'palPillBorder': _argb(p.pillBorder),
      'palDialogBg': _argb(p.dialogBg),
      'palSelected': _argb(p.selected),
    };
  }

  /// 播放态（原生按 positionSec + 本地时钟插值弹幕）。
  /// 页面推全量时顺带跟上这个实例的进度流：播放器只在播停/缓冲变化时 notify，进度要单独推。
  static Map<String, dynamic> playbackFields(KotvPlayback p, {bool forceBuffering = false}) {
    _followPosition(p);
    return {
      'playing': p.playing,
      'buffering': forceBuffering || p.buffering || p.stalling,
      ..._timeFields(p),
      'rate': p.rate,
      'volume': p.volume.clamp(0, 100).toDouble(),
    };
  }

  static Map<String, dynamic> _timeFields(KotvPlayback p) {
    final dur = p.duration;
    final bounded = boundedMediaDurationUs(dur.inMicroseconds);
    _sentPosSec = p.position.inSeconds;
    _sentDurSec = bounded ? dur.inSeconds : -1;
    return {
      'positionSec': p.position.inMilliseconds / 1000.0,
      'durationSec': bounded ? dur.inMilliseconds / 1000.0 : 0.0,
      'bufferedSec': p.buffered.inMilliseconds / 1000.0,
      'bounded': bounded,
    };
  }

  static KotvPlayback? _posOwner;
  static StreamSubscription<Duration>? _posSub;
  static int _sentPosSec = -1;
  static int _sentDurSec = -1;

  static void _followPosition(KotvPlayback p) {
    if (!isNeeded || identical(p, _posOwner)) return;
    _posSub?.cancel();
    _posOwner = p;
    _posSub = p.positionStream.listen((_) {
      // 原生时间显示到秒：秒数或片长变了才推，只带时间字段。
      final dur = p.duration;
      final durSec = boundedMediaDurationUs(dur.inMicroseconds) ? dur.inSeconds : -1;
      if (p.position.inSeconds == _sentPosSec && durSec == _sentDurSec) return;
      unawaited(update(_timeFields(p)));
    });
  }

  static void _stopFollowingPosition() {
    _posSub?.cancel();
    _posSub = null;
    _posOwner = null;
  }

  static bool boundedMediaDurationUs(int us) => us > 0 && us <= 9007199254740991;

  /// 手势 HUD：text（倍速 / 切集提示）、side（亮度音量）、seek（快进快退预览）。
  static Map<String, dynamic> hud({
    String kind = '',
    String text = '',
    String icon = '',
    double size = 18,
    bool ui = true,
  }) =>
      {'hudKind': kind, 'hudText': text, 'hudIcon': icon, 'hudSize': size, 'hudUi': ui};

  // ---------------------------------------------------------------------------
  // 通道
  // ---------------------------------------------------------------------------

  static void _ensureHandler() {
    if (_handlerBound || kIsWeb) return;
    _handlerBound = true;
    _ch.setMethodCallHandler((call) async {
      if (call.method == 'event') {
        final args = call.arguments;
        if (args is Map) onEvent?.call(Map<String, dynamic>.from(args));
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
    _stopFollowingPosition();
    _lastDanmakuSig = 0;
    _lastItemsSig = null;
    unawaited(hideSheet());
    unawaited(update({'mode': ''}));
    unawaited(setEnabled(false));
  }

  static Future<void> setEnabled(bool enabled) async {
    if (!isNeeded) return;
    _ensureHandler();
    try {
      await _ch.invokeMethod('setEnabled', {'enabled': enabled});
      if (!enabled) {
        _lastDanmakuSig = 0;
        _lastItemsSig = null;
      }
    } catch (_) {}
  }

  static Future<void> update(Map<String, dynamic> fields) async {
    if (!isNeeded) return;
    _ensureHandler();
    final mode = fields['mode'];
    final relayout = (mode is String && mode != _lastMode) || fields.containsKey('suspended');
    if (mode is String) _lastMode = mode;
    try {
      await _ch.invokeMethod('update', fields);
    } catch (_) {}
    if (relayout) repaintSoon();
  }

  static String? _lastMode;

  /// 视频 / 手势子窗口缩小或隐藏后，露出来的 Flutter 区域要等下一次出帧才会重画；
  /// 静止页面没有新帧就一直空着（如退出全屏后的详情页）。补几帧。
  static void repaintSoon() {
    if (!isNeeded) return;
    for (final ms in const [16, 150, 500]) {
      Timer(Duration(milliseconds: ms), WidgetsBinding.instance.scheduleForcedFrame);
    }
  }

  static int _suspendDepth = 0;
  static bool _covered = false;
  static bool _sentSuspended = false;

  /// 挂起层归零时自增；mpv 洞监听后重发显隐（与 PopupRouteObserver 互补）。
  static final ValueNotifier<int> unsuspendTick = ValueNotifier<int>(0);

  static Future<void> _pushSuspended() async {
    final want = _suspendDepth > 0 || _covered;
    if (want == _sentSuspended) return;
    _sentSuspended = want;
    await update({'suspended': want});
    if (!want) unsuspendTick.value++;
  }

  /// 播放页被别的 Flutter 路由（对话框、底部弹层）盖住：原生壳是置顶分层窗，须整体挂起。
  /// 由 mpv 洞在路由状态变化时调用。
  static void setCovered(bool covered) {
    if (!isNeeded || covered == _covered) return;
    _covered = covered;
    unawaited(_pushSuspended());
  }

  /// 原生壳挂起（面板、手势层、弹幕全藏）期间跑 Flutter 弹窗；弹窗路由盖住时 mpv 洞也会自己藏 HWND。
  static Future<T> withSuspended<T>(Future<T> Function() body) async {
    if (!isNeeded) return body();
    _suspendDepth++;
    await _pushSuspended();
    try {
      return await body();
    } finally {
      _suspendDepth--;
      await _pushSuspended();
    }
  }

  // ---------------------------------------------------------------------------
  // 网络台标：Dart 拉取解码成 RGBA 交给原生缓存（同 [KotvNetworkImage] 的请求与 dataURI 规则）
  // ---------------------------------------------------------------------------

  /// 台标解码完成时自增；页面监听后重推一次。
  static final ValueNotifier<int> imagesReady = ValueNotifier<int>(0);
  static final Map<String, bool> _imageState = {};

  /// `_LiveChannelLogo._httpLogo`
  static bool isNetworkLogo(String logo) {
    final s = logo.trim();
    return s.startsWith('http://') || s.startsWith('https://') || s.startsWith('proxy://') || s.startsWith('data:');
  }

  /// 网络台标在原生缓存里的 key；非网络台标或加载失败返回空串（原生画首字色块），加载中也返回 key（原生留空）。
  static String logoKey(String logo, {required double width, required double dpr}) {
    final raw = logo.trim();
    if (!isNeeded || !isNetworkLogo(raw)) return '';
    final tw = (width * dpr).ceil().clamp(1, 512);
    final key = '${raw.hashCode.toRadixString(16)}_${raw.length}_$tw';
    final st = _imageState[key];
    if (st == false) return '';
    if (st == null) {
      _imageState[key] = true;
      unawaited(_loadImage(key, raw, tw));
    }
    return key;
  }

  static Future<void> _loadImage(String key, String raw, int targetWidth) async {
    ui.Codec? codec;
    ui.Image? image;
    try {
      var bytes = kotvDecodeDataImage(raw);
      if (bytes == null) {
        final req = kotvResolveImageRequest(raw);
        if (!(req.url.startsWith('http://') || req.url.startsWith('https://'))) {
          throw StateError('empty pic');
        }
        bytes = await kotvFetchImageBytes(req.url, req.headers);
      }
      codec = await ui.instantiateImageCodec(bytes, targetWidth: targetWidth);
      image = (await codec.getNextFrame()).image;
      final data = await image.toByteData(format: ui.ImageByteFormat.rawStraightRgba);
      if (data == null) throw StateError('decode');
      await _ch.invokeMethod('setImage', {
        'key': key,
        'width': image.width,
        'height': image.height,
        'rgba': data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      });
    } catch (_) {
      _imageState[key] = false;
    } finally {
      image?.dispose();
      codec?.dispose();
    }
    imagesReady.value++;
  }

  static Future<void> showSheet({
    required String kind,
    String title = '',
    String subtitle = '',
    required List<Map<String, dynamic>> items,
  }) async {
    if (!isNeeded) return;
    _ensureHandler();
    try {
      await _ch.invokeMethod('showSheet', {
        'kind': kind,
        'title': title,
        'subtitle': subtitle,
        'items': items,
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
    String icon = '',
  }) =>
      showSheet(
        kind: kind,
        title: title,
        subtitle: subtitle,
        items: choiceRows(options, selectedId: selectedId, icon: icon),
      );

  // ---------------------------------------------------------------------------
  // 弹层内容（与 Flutter 弹层逐项对应）
  // ---------------------------------------------------------------------------

  /// [VodFullscreenChrome] `_showMore`。
  static List<Map<String, dynamic>> vodMoreItems({
    required bool repeatOne,
    required bool supportsStableVolume,
    required bool stableVolume,
    required bool loopSkip,
    required int danmakuSourceCount,
    required String danmakuSourceName,
    required bool hasDanmakuSearch,
    required int sleepMinutes,
    required bool hasCast,
    required bool hasMini,
    required bool hasParse,
    required bool hasKeep,
    required String keepLabel,
    required bool supportsRenderMode,
    required String renderLabel,
  }) =>
      [
        row(id: 'videoEq', label: '画面调色', kind: 'link', icon: 'tune', chevron: true),
        row(id: 'audioFx', label: '音频效果', kind: 'link', icon: 'equalizer', chevron: true),
        row(id: 'repeat', label: '循环播放视频', kind: 'toggle', icon: 'repeat', on: repeatOne),
        if (supportsStableVolume)
          row(id: 'stableVolume', label: '稳定音量', kind: 'toggle', icon: 'graphic_eq', on: stableVolume),
        row(id: 'loopSkip', label: '跳过片头片尾', kind: 'toggle', icon: 'skip_next_outlined', on: loopSkip),
        row(id: 'danmakuSettings', label: '弹幕设置', kind: 'link', icon: 'tune', chevron: true),
        if (danmakuSourceCount > 1)
          row(
            id: 'danmakuSource',
            label: '弹幕源',
            kind: 'link',
            icon: 'playlist_play',
            trailing: danmakuSourceName,
            chevron: true,
          ),
        if (hasDanmakuSearch) row(id: 'danmakuSearch', label: '搜索弹幕', kind: 'link', icon: 'manage_search', chevron: true),
        row(
          id: 'sleep',
          label: '休眠定时器',
          kind: 'link',
          icon: 'bedtime_outlined',
          trailing: sleepMinutes <= 0 ? '关闭' : '$sleepMinutes 分钟',
          chevron: true,
        ),
        if (hasCast) row(id: 'cast', label: '投屏', kind: 'link', icon: 'cast', chevron: true),
        if (hasMini) row(id: 'mini', label: '迷你桌面播放', kind: 'link', icon: 'picture_in_picture_alt', chevron: true),
        if (hasParse) row(id: 'parse', label: '解析', kind: 'link', icon: 'auto_awesome', chevron: true),
        row(id: 'replay', label: '刷新', kind: 'link', icon: 'refresh', chevron: true),
        if (hasKeep) row(id: 'keep', label: keepLabel, kind: 'link', icon: 'favorite_border', chevron: true),
        if (supportsRenderMode)
          row(id: 'render', label: '渲染方式', kind: 'link', icon: 'layers_outlined', trailing: renderLabel, chevron: true),
        row(id: 'playInfo', label: '播放信息', kind: 'link', icon: 'info_outline', chevron: true),
        row(id: 'exit', label: '退出全屏', kind: 'link', icon: 'fullscreen_exit', chevron: true),
      ];

  /// [VodFullscreenChrome] `_showSpeedSheet`：大字 + 0.1–5.0 滑条 + 常用倍速。
  static Future<void> showSpeedSheet(double rate) => showSheet(
        kind: 'speed',
        title: '播放倍速',
        items: [
          row(id: 'rate', label: '×${rate.toStringAsFixed(1)}', kind: 'big'),
          slider(
            id: 'rate',
            label: '',
            value: rate,
            min: 0.1,
            max: 5.0,
            divisions: 49,
            format: '×%.1f',
            inline: true,
          ),
          for (final s in vodSpeeds)
            row(id: '$s', label: '×${s == s.roundToDouble() ? s.toStringAsFixed(0) : s}', kind: 'action'),
        ],
      );

  /// [VodFullscreenChrome] `_showVideoEqSheet`。
  static Future<void> showVideoEqSheet(Map<String, String> s) {
    var preset = (s['videoEq'] ?? 'off').trim().toLowerCase();
    if (preset == 'on') preset = 'custom';
    double numOf(String k) => double.tryParse(s[k] ?? '0') ?? 0;
    bool sel(String id) => preset == id || (id == 'off' && (preset.isEmpty || preset == 'off'));
    return showSheet(
      kind: 'videoEq',
      title: '画面调色',
      items: [
        for (final e in videoEqPresets) row(id: e.$1, label: e.$2, kind: 'chip', selected: sel(e.$1)),
        if (preset == 'custom') ...[
          slider(id: 'videoBrightness', label: '亮度', value: numOf('videoBrightness'), min: -100, max: 100, divisions: 40, inline: true),
          slider(id: 'videoContrast', label: '对比度', value: numOf('videoContrast'), min: -100, max: 100, divisions: 40, inline: true),
          slider(id: 'videoSaturation', label: '饱和度', value: numOf('videoSaturation'), min: -100, max: 100, divisions: 40, inline: true),
          slider(id: 'videoSharpness', label: '锐度', value: numOf('videoSharpness'), min: 0, max: 100, divisions: 20, inline: true),
          slider(id: 'videoTemperature', label: '色温', value: numOf('videoTemperature'), min: -100, max: 100, divisions: 40, inline: true),
          row(id: 'preview', label: '按住看原画', kind: 'hold'),
          row(id: 'reset', label: '复位', kind: 'button'),
        ],
      ],
    );
  }

  /// [VodFullscreenChrome] `_showAudioFxSheet`。
  static Future<void> showAudioFxSheet(Map<String, String> s) {
    final eq = (s['audioEq'] ?? 'off').trim().toLowerCase();
    var dialogue = double.tryParse(s['audioDialogue'] ?? '0') ?? 0;
    if ((s['audioDialogue'] ?? '').toLowerCase() == 'true') dialogue = 100;
    final balance = (double.tryParse(s['audioBalance'] ?? '0') ?? 0).clamp(-100.0, 100.0);
    final offset = (double.tryParse(s['audioOffsetMs'] ?? '0') ?? 0).clamp(-5000.0, 5000.0);
    return showSheet(
      kind: 'audioFx',
      title: '音频效果',
      items: [
        for (final e in audioEqPresets) row(id: e.$1, label: e.$2, kind: 'chip', selected: eq == e.$1),
        if (eq == 'custom') ...[
          slider(id: 'audioDialogue', label: '对白', value: dialogue, min: 0, max: 100, divisions: 20, inline: true),
          slider(id: 'audioBalance', label: '平衡', value: balance, min: -100, max: 100, divisions: 40, inline: true),
          slider(
            id: 'audioOffsetMs',
            label: '音画',
            value: offset,
            min: -5000,
            max: 5000,
            divisions: 100,
            format: '%.0f ms',
            inline: true,
          ),
          row(id: 'preview', label: '按住试听原音', kind: 'hold'),
        ],
      ],
    );
  }

  /// `showKotvDanmakuSettingsSheet` 的原生版（时长以秒为单位滑动，提交时换回毫秒）。
  static Future<void> showDanmakuSettingsSheet(Map<String, String> s) {
    String g(String k, [String d = '']) => (s[k] ?? '').trim().isEmpty ? d : s[k]!.trim();
    bool flag(String k, [bool d = true]) => g(k, d ? 'true' : 'false').toLowerCase() == 'true';
    double n(String k, double d) => double.tryParse(g(k, '$d')) ?? d;
    final stroke = g('danmakuStrokeMode', 'outline').toLowerCase();
    final color = g('danmakuColorMode', 'original').toLowerCase();
    final font = g('danmakuFont', 'default').toLowerCase();
    return showSheet(
      kind: 'danmaku',
      title: '弹幕设置',
      items: [
        row(id: 'danmaku', label: '开启弹幕', kind: 'switch', on: flag('danmaku')),
        row(id: 'danmakuLoad', label: '加载弹幕', kind: 'switch', on: flag('danmakuLoad')),
        row(id: 'danmakuAuto', label: '自动搜索弹幕', kind: 'switch', on: flag('danmakuAuto')),
        row(id: 'danmakuSpiderFirst', label: '片源弹幕优先', kind: 'switch', on: flag('danmakuSpiderFirst')),
        row(
          id: 'danmakuApi',
          label: '弹幕 API',
          kind: 'link',
          chevron: true,
          trailing: g('danmakuApi').isEmpty ? '未配置' : '已配置',
        ),
        slider(id: 'danmakuSize', label: '字号', value: n('danmakuSize', 18), min: 12, max: 48, divisions: 36),
        slider(id: 'danmakuOpacity', label: '透明度', value: n('danmakuOpacity', 85), min: 15, max: 100, divisions: 17, format: '%.0f%%'),
        slider(id: 'danmakuRows', label: '行数', value: n('danmakuRows', 6), min: 1, max: 16, divisions: 15),
        slider(id: 'danmakuMaxOnScreen', label: '同屏上限', value: n('danmakuMaxOnScreen', 150), min: 10, max: 500, divisions: 49),
        slider(id: 'danmakuScrollArea', label: '滚动区域', value: n('danmakuScrollArea', 50), min: 10, max: 100, divisions: 18, format: '%.0f%%'),
        slider(id: 'danmakuScrollGap', label: '水平间距', value: n('danmakuScrollGap', 8), min: 0, max: 20, divisions: 20, format: '%.0f%%'),
        slider(
          id: 'danmakuOffsetS',
          label: '时轴偏移',
          value: n('danmakuOffsetMs', 0) / 1000,
          min: -300,
          max: 300,
          divisions: 120,
          format: '%+.0f s',
        ),
        row(id: 'danmakuShowScroll', label: '滚动弹幕', kind: 'switch', on: flag('danmakuShowScroll')),
        row(id: 'danmakuShowTop', label: '顶部弹幕', kind: 'switch', on: flag('danmakuShowTop')),
        row(id: 'danmakuShowBottom', label: '底部弹幕', kind: 'switch', on: flag('danmakuShowBottom')),
        row(id: 'danmakuShowReverse', label: '逆向弹幕', kind: 'switch', on: flag('danmakuShowReverse')),
        row(id: 'danmakuShowPositioned', label: '定位弹幕', kind: 'switch', on: flag('danmakuShowPositioned')),
        row(id: 'danmakuShowSpecial', label: '特殊弹幕', kind: 'switch', on: flag('danmakuShowSpecial')),
        row(id: 'danmakuBold', label: '粗体', kind: 'switch', on: flag('danmakuBold', false)),
        row(
          id: 'danmakuStrokeMode',
          label: '描边样式',
          kind: 'link',
          chevron: true,
          trailing: switch (stroke) {
            'none' => '无',
            'outline' => '描边',
            'projection' => '投影',
            _ => '阴影',
          },
        ),
        row(
          id: 'danmakuColorMode',
          label: '颜色策略',
          kind: 'link',
          chevron: true,
          trailing: switch (color) {
            'white' => '白色',
            'yellow' => '黄色',
            _ => '原色',
          },
        ),
        row(
          id: 'danmakuFont',
          label: '弹幕字体',
          kind: 'link',
          chevron: true,
          trailing: switch (font) {
            'sans' || 'sans-serif' => '无衬线',
            'serif' => '衬线',
            'mono' || 'monospace' => '等宽',
            _ => '默认',
          },
        ),
        slider(id: 'danmakuRowsTop', label: '顶部行数', value: n('danmakuRowsTop', 3), min: 1, max: 8, divisions: 7),
        slider(id: 'danmakuRowsBottom', label: '底部行数', value: n('danmakuRowsBottom', 3), min: 1, max: 8, divisions: 7),
        slider(
          id: 'danmakuDurationS',
          label: '滚动时长',
          value: n('danmakuDurationMs', 8000) / 1000,
          min: 3,
          max: 15,
          divisions: 24,
          format: '%.1f s',
        ),
        slider(
          id: 'danmakuFixedDurationS',
          label: '固定时长',
          value: n('danmakuFixedDurationMs', 5000) / 1000,
          min: 2,
          max: 10,
          divisions: 16,
          format: '%.1f s',
        ),
        slider(id: 'danmakuLineSpacing', label: '行距', value: n('danmakuLineSpacing', 1.4), min: 1, max: 2, divisions: 10, format: '%.1f'),
      ],
    );
  }

  /// 弹幕设置里三个「选一项」子弹层。
  static Future<void> showDanmakuChoice(String id, Map<String, String> s) {
    final cur = (s[id] ?? '').trim().toLowerCase();
    switch (id) {
      case 'danmakuStrokeMode':
        return showChoiceSheet(
          kind: 'danmakuChoice:$id',
          title: '弹幕描边',
          selectedId: cur.isEmpty ? 'outline' : cur,
          options: const [('none', '无'), ('outline', '描边'), ('shadow', '阴影'), ('projection', '投影')],
        );
      case 'danmakuColorMode':
        return showChoiceSheet(
          kind: 'danmakuChoice:$id',
          title: '弹幕颜色',
          selectedId: cur.isEmpty ? 'original' : cur,
          options: const [('original', '保留原色'), ('white', '白色'), ('yellow', '黄色')],
        );
      default:
        return showChoiceSheet(
          kind: 'danmakuChoice:danmakuFont',
          title: '弹幕字体',
          selectedId: cur == 'sans-serif' ? 'sans' : (cur == 'monospace' ? 'mono' : (cur.isEmpty ? 'default' : cur)),
          options: const [('default', '默认'), ('sans', '无衬线'), ('serif', '衬线'), ('mono', '等宽')],
        );
    }
  }

  /// 弹幕设置项落盘：开关。返回是否已处理。
  static Future<bool> persistDanmakuToggle({
    required String id,
    required bool on,
    required Future<void> Function(String key, String value) persist,
  }) async {
    if (id != 'danmaku' && !id.startsWith('danmaku')) return false;
    await persist(id, on ? 'true' : 'false');
    return true;
  }

  /// 弹幕设置项落盘：滑条（秒制滑条换回毫秒）。返回是否已处理。
  static Future<bool> persistDanmakuSlider({
    required String id,
    required double value,
    required Future<void> Function(String key, String value) persist,
  }) async {
    switch (id) {
      case 'danmakuOffsetS':
        await persist('danmakuOffsetMs', '${(value * 1000).round()}');
        return true;
      case 'danmakuDurationS':
        await persist('danmakuDurationMs', '${(value * 1000).round()}');
        return true;
      case 'danmakuFixedDurationS':
        await persist('danmakuFixedDurationMs', '${(value * 1000).round()}');
        return true;
      case 'danmakuLineSpacing':
        await persist(id, value.toStringAsFixed(1));
        return true;
      default:
        if (!id.startsWith('danmaku')) return false;
        await persist(id, '${value.round()}');
        return true;
    }
  }

  /// [VodFullscreenChrome] `_showPlayerDialog`。
  static Future<void> showPlayerPickerSheet({
    required String currentId,
    required String currentLabel,
    required List<(String label, String id)> options,
  }) =>
      showSheet(
        kind: 'player',
        title: '请选择播放器',
        subtitle: '当前：$currentLabel',
        items: [
          for (final o in options) row(id: o.$2, label: o.$1, icon: 'smart_display_outlined', selected: o.$2 == currentId),
        ],
      );

  // ---------------------------------------------------------------------------
  // 弹幕
  // ---------------------------------------------------------------------------

  static Future<void> setDanmaku({
    required bool enabled,
    required List<DanmakuItem> items,
    double fontSize = 18,
    double opacity = 0.85,
    int durationMs = 8000,
    int fixedDurationMs = 5000,
    int rows = 6,
    int maxOnScreen = 150,
    double scrollArea = 0.5,
    bool bold = false,
    bool showScroll = true,
    bool showTop = true,
    bool showBottom = true,
    bool showReverse = true,
    bool showPositioned = true,
    bool showSpecial = true,
    double lineSpacing = 1.4,
    String strokeMode = 'outline',
    String colorMode = 'original',
    int rowsTop = 3,
    int rowsBottom = 3,
    double scrollGap = 0.08,
    double strokeWidth = 0.12,
    double shadowOpacity = 0.5,
    double projectionOffsetX = 0.08,
    double projectionOffsetY = 0.08,
    double projectionOpacity = 0.2,
  }) async {
    if (!isNeeded) return;
    _ensureHandler();
    final sig = Object.hashAll([
      items.length,
      items.isEmpty ? 0 : items.first.time,
      items.isEmpty ? 0 : items.last.time,
      items.isEmpty ? 0 : items.first.content.hashCode,
      enabled,
      fontSize,
      opacity,
      durationMs,
      fixedDurationMs,
      rows,
      maxOnScreen,
      scrollArea,
      bold,
      showScroll,
      showTop,
      showBottom,
      showReverse,
      showPositioned,
      showSpecial,
      lineSpacing,
      strokeMode,
      colorMode,
      rowsTop,
      rowsBottom,
      scrollGap,
      strokeWidth,
      shadowOpacity,
      projectionOffsetX,
      projectionOffsetY,
      projectionOpacity,
    ]);
    if (sig == _lastDanmakuSig) return;
    final itemsSig = Object.hash(items.length, items.isEmpty ? 0 : items.first.time, items.isEmpty ? 0 : items.last.time);
    final sendItems = itemsSig != (_lastItemsSig ?? -1);
    _lastDanmakuSig = sig;
    _lastItemsSig = itemsSig;
    try {
      final map = <String, dynamic>{
        'enabled': enabled,
        'fontSize': fontSize,
        'opacity': opacity,
        'durationMs': durationMs,
        'fixedDurationMs': fixedDurationMs,
        'rows': rows,
        'maxOnScreen': maxOnScreen,
        'scrollArea': scrollArea,
        'bold': bold,
        'showScroll': showScroll,
        'showTop': showTop,
        'showBottom': showBottom,
        'showReverse': showReverse,
        'showPositioned': showPositioned,
        'showSpecial': showSpecial,
        'lineSpacing': lineSpacing,
        'strokeMode': strokeMode,
        'colorMode': colorMode,
        'rowsTop': rowsTop,
        'rowsBottom': rowsBottom,
        'scrollGap': scrollGap,
        'strokeWidth': strokeWidth,
        'shadowOpacity': shadowOpacity,
        'projectionOffsetX': projectionOffsetX,
        'projectionOffsetY': projectionOffsetY,
        'projectionOpacity': projectionOpacity,
      };
      if (sendItems) {
        const maxItems = 4000;
        final src = items.length > maxItems ? items.sublist(items.length - maxItems) : items;
        map['items'] = [
          for (final it in src)
            {
              't': it.time,
              'c': it.content,
              'm': it.mode,
              'color': it.color,
              'size': it.size,
              'pool': it.pool,
              'x': it.x,
              'y': it.y,
              'dur': it.durationMs,
            },
        ];
      }
      await _ch.invokeMethod('setDanmaku', map);
    } catch (_) {}
  }

  static int? _lastItemsSig;

  // ---------------------------------------------------------------------------
  // 指针 / 按键
  // ---------------------------------------------------------------------------

  static int _pointerId = 0x4B000;
  static Offset _lastPointer = Offset.zero;

  /// 原生手势层的指针事件 → Flutter [PointerEvent]（全局逻辑坐标；[origin] 为监听区左上角）。
  /// `scroll` 返回 null，由调用方按 dx/dy/shift 走滚轮逻辑。
  static PointerEvent? pointerEvent(Map<String, dynamic> e, {Offset origin = Offset.zero}) {
    final pos = Offset((e['x'] as num?)?.toDouble() ?? 0, (e['y'] as num?)?.toDouble() ?? 0);
    final ts = Duration(microseconds: DateTime.now().microsecondsSinceEpoch);
    final delta = pos - _lastPointer;
    _lastPointer = pos;
    final transform = origin == Offset.zero ? null : Matrix4.translationValues(-origin.dx, -origin.dy, 0);
    const kind = PointerDeviceKind.mouse;
    final PointerEvent ev;
    switch (e['phase'] as String? ?? '') {
      case 'down':
        _pointerId++;
        ev = PointerDownEvent(pointer: _pointerId, kind: kind, position: pos, buttons: kPrimaryButton, timeStamp: ts);
      case 'move':
        ev = PointerMoveEvent(
          pointer: _pointerId,
          kind: kind,
          position: pos,
          delta: delta,
          buttons: kPrimaryButton,
          timeStamp: ts,
        );
      case 'up':
        ev = PointerUpEvent(pointer: _pointerId, kind: kind, position: pos, timeStamp: ts);
      case 'cancel':
        ev = PointerCancelEvent(pointer: _pointerId, kind: kind, position: pos, timeStamp: ts);
      case 'hover':
        ev = PointerHoverEvent(kind: kind, position: pos, delta: delta, timeStamp: ts);
      case 'exit':
        ev = PointerExitEvent(kind: kind, position: pos, timeStamp: ts);
      default:
        return null;
    }
    return transform == null ? ev : ev.transformed(transform);
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
      case 'Backspace':
        return LogicalKeyboardKey.backspace;
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
          final d = int.tryParse(name.substring(5));
          if (d != null && d >= 0 && d <= 9) return LogicalKeyboardKey(LogicalKeyboardKey.digit0.keyId + d);
        }
        return null;
    }
  }

  /// 由原生壳 key 事件构造 Flutter [KeyEvent]（供页面复用自己的 `_onKey`）。
  static KeyEvent? keyEventFromMap(Map<String, dynamic> e) {
    final logical = logicalKeyFromName(e['logical'] as String? ?? '');
    if (logical == null) return null;
    const time = Duration.zero;
    final physical = PhysicalKeyboardKey(logical.keyId & 0xFFFFFFFF);
    if (e['up'] == true) return KeyUpEvent(physicalKey: physical, logicalKey: logical, timeStamp: time);
    if (e['repeat'] == true) return KeyRepeatEvent(physicalKey: physical, logicalKey: logical, timeStamp: time);
    return KeyDownEvent(physicalKey: physical, logicalKey: logical, timeStamp: time);
  }
}

/// 原生壳的 [KotvBufferingOverlay]：同样的显隐条件与每秒测速，文案推给原生 `bufferText`（空串即隐藏）。
class KotvWinBufferText {
  KotvWinBufferText(this.onChanged);

  /// 网速变化或缓冲结束时回调，页面据此重推。
  final VoidCallback onChanged;
  Timer? _tick;
  int _speedBps = 0;
  bool _armed = false;
  bool _disposed = false;
  KotvPlayback? _player;
  bool _force = false;

  bool get _want => _force || (_player?.stalling ?? false);

  String label(KotvPlayback? player, {bool force = false, String? forceText}) {
    _player = player;
    _force = force;
    final want = _want;
    _arm(want);
    if (!want) return '';
    final forced = forceText?.trim();
    if (forced != null && forced.isNotEmpty) return forced;
    return '缓冲中  ${kotvFormatSpeed(_speedBps, showZero: true)}';
  }

  void _arm(bool on) {
    if (_disposed) return;
    if (on) {
      if (!_armed) {
        KotvTraffic.reset();
        _armed = true;
        _speedBps = 0;
        unawaited(_poll());
      }
      _tick ??= Timer.periodic(const Duration(milliseconds: 1000), (_) {
        if (!_want) {
          _arm(false);
          onChanged();
          return;
        }
        unawaited(_poll());
      });
    } else {
      _tick?.cancel();
      _tick = null;
      if (_armed) {
        KotvTraffic.reset();
        _armed = false;
      }
    }
  }

  Future<void> _poll() async {
    final v = await KotvTraffic.sampleBps(playerFallbackBps: _player?.networkSpeedBps ?? 0);
    if (_disposed || !_armed) return;
    if (v != _speedBps) {
      _speedBps = v;
      onChanged();
    }
  }

  void dispose() {
    _arm(false);
    _disposed = true;
  }
}
