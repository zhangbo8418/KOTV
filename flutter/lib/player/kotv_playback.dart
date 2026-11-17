import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'keep_awake.dart';

/// 播放信息里的解码器名，一律大写（D3D11VA-COPY、DXVA2、FFMPEG…）。
String kotvDecoderName(String raw) => raw.trim().toUpperCase();

/// mpv `hwdec-current` → 播放信息文案（桌面 media_kit 与安卓原生 MPV 共用）。
String? kotvMpvHwdecLabel(String raw) {
  final v = raw.trim();
  if (v.isEmpty) return null;
  if (v == 'no') return '软解';
  return '${v.endsWith('-copy') ? '硬解后拷贝' : '硬解直出'}（${kotvDecoderName(v)}）';
}

/// 原生播放器 videoInfo → 「PQ · BT.2020 · 杜比视界 P7 · 杜比视界直出（显示器：HDR10/HLG）」。
String? kotvVideoColorLabel(Map<Object?, Object?>? info) {
  if (info == null) return null;
  String s(String k) => '${info[k] ?? ''}'.trim();
  final parts = [
    for (final k in const ['transfer', 'primaries', 'dolbyVision', 'output'])
      if (s(k).isNotEmpty) s(k),
  ];
  final display = s('display');
  if (parts.isEmpty && display.isEmpty) return null;
  final head = parts.isEmpty ? '未知' : parts.join(' · ');
  return display.isEmpty ? head : '$head（显示器：$display）';
}

/// 统一播放后端：Exo / 原生 MPV / FVP / HTML 等共用同一套菜单/控件。
abstract class KotvPlayback extends ChangeNotifier {
  bool? _keepAwakeWant;

  bool get playing;
  bool get completed;
  /// 单集循环开启时，播完不应自动切下一集。
  bool get repeatOne => false;
  Duration get position;
  Duration get duration;
  /// 已缓冲到的位置（用于进度条 secondary track）；未知时为 zero。
  Duration get buffered => Duration.zero;
  /// 是否正在缓冲（卡顿补缓冲 / 起播缓冲）。
  ///
  /// 已出画后的补缓存不要用这个判断（避免误切播放器）；中央按钮 / 缓冲浮层请用 [stalling]。
  bool get buffering => false;
  /// 起播或播放中卡顿：给「缓冲中」浮层和中央播停键。
  bool get stalling => buffering;
  /// 是否改由原生画缓冲浮层。当前一律 false：统一走 Flutter [KotvBufferingOverlay]。
  /// 估算下载速度（字节/秒）；0 表示未知。
  int get networkSpeedBps => 0;
  double get volume; // 0–100
  double get rate;
  int get width;
  int get height;
  String get engineLabel;

  /// 当前实际在用的视频解码方式（播放信息里展示）；读不到时为 null。
  Future<String?> activeDecoderLabel() async => null;

  /// 片源色彩与显示器 HDR 能力（播放信息里展示，见 [kotvVideoColorLabel]）；读不到时为 null。
  Future<String?> videoColorLabel() async => null;

  Stream<Duration> get positionStream;

  /// 缓冲位置变化（可选；UI 也可靠 [ChangeNotifier]）。
  Stream<Duration> get bufferedStream => const Stream<Duration>.empty();

  /// 本集自然播完（非手动 stop）时发出 true。
  Stream<bool> get completedStream;

  /// 最近一次播放错误文案；无错误为 null。播放中失败换线等可订阅 [addListener] 后读此字段。
  String? get lastError => null;

  /// [live]=true：直播页语境。内存缓冲仍按同一比例封顶，不做点播磁盘预读。
  /// [startAt]>0：开播定位。MPV=Media/loadfile start；FVP=prepare(ms)（勿 prepare(0) 后再 seek）。
  /// [waitReady]=false：只把媒体交给引擎即返回（直播换台）；出画守卫由调用方后台跑。
  /// 默认 true：等 silent-video 守卫完成（点播详情）。
  Future<void> open(
    String url, {
    Map<String, String>? headers,
    Map<String, dynamic>? drm,
    bool live = false,
    String? format,
    Duration startAt = Duration.zero,
    bool waitReady = true,
  });

  /// [open] 在 [waitReady]=false 时跳过的出画守卫；直播换台后台调用以触发 failover。
  Future<void> awaitReadyAfterOpen() async {}

  /// 把下一集排进播放器自己的播放列表，本集播完无缝接上；播到它时 [queuedStartStream] 发出 [id]。
  /// [startAt]>0：切入该集时的起播定位（片头跳过），与 [open] 的 startAt 同语义，须写进列表项本身，勿等切入后再 seek。
  /// Exo、全部 MPV（安卓原生 + 桌面/iOS media_kit）支持；FVP / 网页返回 false，换集仍走 [open]。
  /// 单集循环开启时各引擎应拒绝排队（由 [setRepeatOne]/[clearNext] 撤掉已排项）。
  ///
  /// MPV keep-open 契约（桌面 media_kit + 安卓原生共用；Exo 不走 keep-open）：
  /// - 无排队 / 单集：`keep-open=yes`，末项结束 pause，`eof-reached`→completed，供硬切下一集或再播回起点；
  /// - [queueNext] 成功：`keep-open=no`，本集 EOF 由 mpv 自然进已 append 项，不经片尾 pause；
  /// - 切入排队项 / [clearNext]：恢复 `yes`，新当前集仍能报 completed（media_kit 依赖 eof-reached）；
  /// - 官方语义：`yes` 仅卡在播放列表**最后一项**；有下一项时应前进。排队时显式 `no`，避免 media_kit
  ///   在 eof-reached 上把 playing 打成 false 造成可见顿挫。
  /// 手动 [skipToNext]：写 `playlist-pos`（或 playlist-next）+ `pause=no`；勿用 media_kit 的
  /// `Player.next`/`play`（completed 时会把 playlist-pos 置 0）。
  Future<bool> queueNext({
    required String id,
    required String url,
    Map<String, String>? headers,
    String? format,
    List<Map<String, dynamic>> subs = const [],
    Duration startAt = Duration.zero,
  }) async =>
      false;

  /// 立刻跳到排好的下一集（片尾跳过、下一集按钮）；没排上返回 false。
  Future<bool> skipToNext() async => false;

  /// 撤掉排好的下一集（如打开单集循环）；MPV 同时恢复 `keep-open=yes`。
  Future<void> clearNext() async {}

  Stream<String> get queuedStartStream => const Stream<String>.empty();
  Future<void> playOrPause();
  Future<void> play();
  Future<void> pause();
  Future<void> stop();
  /// 硬切换集/换台：只卸当前文件（或 FVP 拆缓冲），保留视频层。
  /// 消音由 [kotvStopPlayersForEpisodeSwitch] 统一先 [pause]；本方法内勿再 pause。
  /// 无缝 [skipToNext] 不调用。
  Future<void> stopForEpisodeSwitch() => stop();
  Future<void> seek(Duration d);
  Future<void> setVolume(double v);
  Future<void> setRate(double r);
  Future<void> setRepeatOne(bool on);
  Future<void> setDecodeMode(String mode);

  /// 硬解直出开关（仅 Win7 MPV：开=dxva2；关=hwdec=auto，与 Win10 相同）。Win7 以上不显示。
  /// 切换要换播放器（见 [kotvMediaKitNeedsNewPlayer]），由页面按新选项重建。
  bool get supportsDirectOutput => false;
  bool get directOutput => true;

  /// Android Exo / 原生 MPV：Surface / Texture；其它后端忽略。
  Future<void> setRenderMode(String mode) async {}

  /// 当前后端是否真的能切 Surface / Texture（播放菜单按实际后端显示入口）。
  bool get supportsRenderMode => false;

  /// 后台「仅音频」时卸掉画面输出（音继续）；回前台再挂上。其它后端默认空实现。
  Future<void> setVideoOutputEnabled(bool enabled) async {}

  /// 画面比例：`default` 适应 / `fill` 拉伸 / `zoom` 裁切 / `16:9` / `4:3`。
  /// 原生 Surface 吃不到 Flutter BoxFit，需引擎侧落实；默认空实现。
  Future<void> setVideoScale(String mode) async {}

  /// 音量归一（loudnorm / dynaudnorm）；不支持的引擎忽略。
  Future<void> setStableVolume(bool on) async {}

  /// 当前后端是否实现了 [setStableVolume]。
  bool get supportsStableVolume => false;

  /// 是否认为已挂上可用视频源（轨/元数据）。无法判断时返回 true。
  bool get hasVideoSourceHint => true;

  /// 已确认是纯音频（无视频轨且有音轨）；此时不应要求出画面。
  bool get isAudioOnlyContent => false;

  /// 尝试修复视源：能枚举轨的引擎应重选视频轨；否则软重试（seek/play）。
  Future<void> tryFixVideoSource() async {}

  /// 当前片源可切换的真实音轨（不含引擎注入的 `auto` / `no` 控制项）。
  List<KotvTrack> get audioTracks;
  /// 当前片源可切换的真实视频轨（不含 `auto`）；无法枚举时为空。
  List<KotvTrack> get videoTracks => const [];
  /// 当前片源可切换的真实字幕轨（同上；关闭/自动请用 [setSubtitleTrack]）。
  List<KotvTrack> get subtitleTracks;
  String? get currentAudioId;
  String? get currentVideoId => null;
  String? get currentSubtitleId;
  /// 副字幕轨 id；无副字幕时为 null / off。
  String? get currentSecondarySubtitleId => null;
  Future<void> setAudioTrack(String id);
  Future<void> setVideoTrack(String id) async {}
  Future<void> setSubtitleTrack(String id); // ''=关, 'auto'=自动

  /// 副字幕轨：''/off=关，'auto'=自动，其余为轨 id；不支持的引擎忽略。
  Future<void> setSecondarySubtitleTrack(String id) async {}

  /// 碟片导航（DVD/BD）；不支持时 [supportsDiscNav] 为 false。
  bool get supportsDiscNav => false;
  Future<List<KotvTrack>> discTitles() async => const [];
  Future<List<KotvTrack>> discChapters() async => const [];
  Future<void> setDiscTitle(int index) async {}
  Future<void> setDiscChapter(int index) async {}
  Future<void> openDiscMenu() async {}

  /// 下次 [open] 附加属性（如 `force-iso` / `dvd-device`）；默认忽略。
  void setExtraOpenProps(Map<String, String> props) {}

  /// 外挂字幕文件（本地路径或 URL）；不支持的引擎忽略。
  Future<void> addSubtitleFile(String path, {String? title}) async {}

  /// 按路径加外挂字幕，标题取文件名（本地选择 / 远端推来的字幕路径）。
  Future<void> addSubtitlePath(String path) {
    final p = path.trim();
    if (p.isEmpty) return Future.value();
    return addSubtitleFile(p, title: p.split(RegExp(r'[/\\]')).last);
  }

  /// 字幕样式（字号/位置/颜色等）；不支持的引擎忽略。
  Future<void> setSubtitleStyle({
    double? scale,
    double? pos,
    double? secondaryPos,
    bool forceStyle = false,
    String? color,
    String? borderColor,
    double? borderSize,
    String? bgColor,
    String? edgeType,
    bool useSystemStyle = false,
    double? textOpacity,
    double? bgOpacity,
    double? edgeOpacity,
    double? shadowStrength,
    String? font,
    String? fontPath,
  }) async {}

  /// 字幕时间偏移（毫秒）；正值字幕延后。不支持的引擎忽略。
  Future<void> setSubtitleOffsetMs(int offsetMs) async {}

  /// 音画偏移（毫秒）；正值音频延后。不支持的引擎忽略。
  Future<void> setAudioOffsetMs(int offsetMs) async {}

  /// 临时旁路画面/音频效果（按住看原画 / 试听原音）；松手后恢复。
  Future<void> setFxPreview({bool? videoOriginal, bool? audioOriginal}) async {}

  /// 查询设备 Equalizer 中心频率（Hz）；失败返回空。
  Future<List<int>> queryAudioEqCenters() async => const [];

  /// 离开详情/直播/切 Tab：拆掉原生播放器与 AO，避免后台漏音。
  ///
  /// **页面契约**：soft pause → `await release()` → 再清 `_playUrl` 卸宿主 →
  /// `dispose()` 包装类。`release()` 内须先停声并拆掉原生绑定。
  /// Texture / Exo / MPV / FVP：release 内或插件侧清面后即可删 player。
  /// 默认等同 [stop]；原生引擎应覆盖为 stop 后销毁实例。
  Future<void> release() => stop();

  /// Web 浏览器画中画；其它平台默认不支持。
  bool get supportsPictureInPicture => false;
  bool get pictureInPictureActive => false;
  void Function(bool active)? onPictureInPictureChanged;
  Future<bool> enterPictureInPicture() async => false;
  Future<void> exitPictureInPicture() async {}

  bool _notifierGone = false;

  /// 播放或缓冲中保持屏幕常亮；暂停/停止/销毁时释放。
  void _syncKeepAwake() {
    final want = playing || stalling;
    if (_keepAwakeWant == want) return;
    _keepAwakeWant = want;
    KotvKeepAwake.setHolding(this, want);
  }

  @override
  void notifyListeners() {
    if (_notifierGone) return;
    _syncKeepAwake();
    super.notifyListeners();
  }

  @override
  void dispose() {
    _notifierGone = true;
    if (_keepAwakeWant == true) {
      _keepAwakeWant = false;
      KotvKeepAwake.setHolding(this, false);
    }
    super.dispose();
  }
}

/// 离开播放统一拆机：stop → 短等排空 AO/事件线程 → dispose。
///
/// 对应 Windows media_kit [kotvDisposeMpvPlayer]；各平台 MPV / FVP / Exo 共用。
/// 调用方宜先 pause；本函数不改音量。勿把 dispose 丢后台（会泄漏缓冲）。
Future<void> kotvTeardownPlayback({
  required Future<void> Function() stop,
  required Future<void> Function() dispose,
  Duration drain = const Duration(milliseconds: 400),
}) async {
  try {
    await stop();
  } catch (_) {}
  await Future<void>.delayed(drain);
  try {
    await dispose();
  } catch (_) {}
}

/// 页面硬停前：对各后端 soft pause（停声，不改包装类音量）。
Future<void> kotvSoftPausePlayers(Iterable<KotvPlayback?> players) async {
  Future<void> one(KotvPlayback? p) async {
    if (p == null) return;
    try {
      await p.pause();
    } catch (_) {}
  }

  await Future.wait<void>(players.map(one));
}

/// 硬切换集/换台停播：先 [kotvSoftPausePlayers] 消音，再各后端 [KotvPlayback.stopForEpisodeSwitch] 卸文件。
/// 消音只在此做一次；后端不要再 pause。无缝 [skipToNext] 不调用。
Future<void> kotvStopPlayersForEpisodeSwitch(Iterable<KotvPlayback?> players) async {
  final list = players.toList(growable: false);
  await kotvSoftPausePlayers(list);
  Future<void> one(KotvPlayback? p) async {
    if (p == null) return;
    try {
      await p.stopForEpisodeSwitch();
    } catch (_) {}
  }

  await Future.wait<void>(list.map(one));
}

/// 页面硬停：先 [KotvPlayback.release]（含 FVP 先卸 PlatformView 再删 mdk），
/// **调用方再清 `_playUrl` 卸页面宿主**。
///
/// [waitFirst]（通常为 FVP）单独等完卸面+dispose，勿与其它后端共用 timeout 半路放弃。
Future<void> kotvHardReleasePlayers(
  Iterable<KotvPlayback?> players, {
  KotvPlayback? waitFirst,
  Duration waitFirstTimeout = const Duration(seconds: 3),
  Duration othersTimeout = const Duration(seconds: 2),
}) async {
  Future<void> one(KotvPlayback? p) async {
    if (p == null) return;
    try {
      await p.release();
    } catch (_) {
      try {
        await p.stop();
      } catch (_) {}
    }
  }

  if (waitFirst != null) {
    try {
      await one(waitFirst).timeout(waitFirstTimeout);
    } catch (_) {}
  }
  final rest = <Future<void>>[];
  for (final p in players) {
    if (p == null || identical(p, waitFirst)) continue;
    rest.add(one(p));
  }
  if (rest.isEmpty) return;
  await Future.wait<void>(rest).timeout(othersTimeout, onTimeout: () => <void>[]);
}

/// 起播作废后，播放器还在 [owned] 里就留给下一次起播；已经摘掉的再停一次，避免打开晚到后出声。
Future<void> kotvStopIfUnowned(KotvPlayback pb, Iterable<KotvPlayback?> owned) async {
  for (final current in owned) {
    if (identical(pb, current)) return;
  }
  try {
    await pb.pause();
  } catch (_) {}
  try {
    await pb.stop();
  } catch (_) {}
}

/// [KotvPlayback.release] 之后销毁 Dart 包装类（勿在 release 前调用）。
void kotvDisposePlaybackWrappers(Iterable<KotvPlayback?> players) {
  for (final p in players) {
    if (p == null) continue;
    try {
      p.dispose();
    } catch (_) {}
  }
}

/// 网速文案：统一两位小数，如 `0.00 KB/s` / `12.34 KB/s` / `100.00 MB/s`。
/// [showZero] 为 true 时，0 也显示（缓冲界面用来判断是否卡死）。
String kotvFormatSpeed(int bytesPerSec, {bool showZero = false}) {
  if (bytesPerSec <= 0) return showZero ? '0.00 KB/s' : '';
  final kb = bytesPerSec / 1024.0;
  if (kb < 1024) {
    return '${kb.toStringAsFixed(2)} KB/s';
  }
  return '${(kb / 1024.0).toStringAsFixed(2)} MB/s';
}

class KotvTrack {
  const KotvTrack({
    required this.id,
    required this.label,
    this.language = '',
    this.codec = '',
  });
  final String id;
  final String label;
  /// 轨道语言（容器元数据）；未知为空。
  final String language;
  /// 解码器/编码名（如 h264、png）；未知为空。
  final String codec;
}

/// 语言主标签（zh-Hans / zh_CN → zh）；未知或 und 为空串。
String kotvLangKey(String lang) {
  final k = lang.trim().toLowerCase().split(RegExp(r'[-_]')).first;
  return k == 'und' ? '' : k;
}

/// 桌面端关窗前注册：先硬停页面内播放器，再销毁 FlutterEngine，
/// 避免原生播放核心与 `shutDownEngine` 竞态 SIGSEGV。
typedef KotvQuitHook = Future<void> Function();

final List<KotvQuitHook> _kotvQuitHooks = <KotvQuitHook>[];

void kotvRegisterQuitHook(KotvQuitHook hook) {
  if (!_kotvQuitHooks.contains(hook)) {
    _kotvQuitHooks.add(hook);
  }
}

void kotvUnregisterQuitHook(KotvQuitHook hook) {
  _kotvQuitHooks.remove(hook);
}

Future<void> kotvRunQuitHooks() async {
  final hooks = List<KotvQuitHook>.of(_kotvQuitHooks);
  await Future.wait<void>(hooks.map((h) async {
    try {
      await h().timeout(const Duration(seconds: 3));
    } catch (_) {}
  }));
}

/// 引擎注入的轨控制项（auto / no），UI 枚举真实轨时应过滤。
bool kotvIsPseudoMediaTrack(String id) {
  switch (id.toLowerCase().trim()) {
    case 'auto':
    case 'no':
      return true;
    default:
      return id.trim().isEmpty;
  }
}

/// 静止图/封面类「视频」编码（HLS 分片常为 png/mjpeg）。
/// 不算可出画的实视频轨：不应挡纯音频叠层，也不应把瞬时 EOF 当正常片尾连播。
bool kotvIsImageMediaCodec(String? codec) {
  final raw = (codec ?? '').trim().toLowerCase();
  if (raw.isEmpty) return false;
  final base = raw.split(RegExp(r'[.\s/]')).firstWhere(
        (s) => s.isNotEmpty,
        orElse: () => raw,
      );
  switch (base) {
    case 'png':
    case 'mjpeg':
    case 'mjpg':
    case 'jpeg':
    case 'jpg':
    case 'webp':
    case 'bmp':
    case 'gif':
    case 'tiff':
    case 'tif':
    case 'ppm':
    case 'pgm':
      return true;
    default:
      return raw.contains('png') || raw.startsWith('mjpeg') || raw.startsWith('mjpg');
  }
}

/// 是否算「实视频轨」：非伪轨、非图片编码；[image]/[albumart] 为 true 时也排除。
bool kotvIsRealVideoTrack({
  required String id,
  String? codec,
  bool image = false,
  bool albumart = false,
}) {
  if (kotvIsPseudoMediaTrack(id)) return false;
  if (image || albumart) return false;
  if (kotvIsImageMediaCodec(codec)) return false;
  return true;
}

bool kotvSubtitleIsOff(String? id) {
  if (id == null) return true;
  switch (id.toLowerCase().trim()) {
    case '':
    case 'no':
    case 'none':
    case 'off':
      return true;
    case 'auto':
      return false;
    default:
      return false;
  }
}

bool kotvSubtitleIsAuto(String? id) => (id ?? '').toLowerCase().trim() == 'auto';

bool kotvAudioIsAuto(String? id) {
  if (id == null || id.trim().isEmpty) return true;
  return id.toLowerCase().trim() == 'auto';
}

/// 设置项布尔：null 或空串用 [def]；显式 false/off/0/no 为关，其余为开。
bool kotvSettingsFlag(Object? raw, {bool def = false}) {
  final t = (raw == null ? '' : '$raw').trim().toLowerCase();
  if (t.isEmpty) return def;
  return t != 'false' && t != 'off' && t != '0' && t != 'no';
}

bool kotvSettingsMapFlag(Map<String, dynamic> settings, String key, {bool def = false}) =>
    kotvSettingsFlag(settings[key], def: def);

void kotvDisposePlaybackStreams({
  required Future<void> Function() stop,
  required StreamController<Duration> position,
  required StreamController<Duration> buffered,
  required StreamController<bool> completed,
}) {
  unawaited(stop());
  position.close();
  buffered.close();
  completed.close();
}

/// MPV / FVP / Exo 开播后长时间无视频尺寸（有声无画或 Texture 0×0）。
class KotvSilentVideoException implements Exception {
  const KotvSilentVideoException([this.message = '播放器无画面']);
  final String message;
  @override
  String toString() => message;
}

/// 正在播就暂停，否则播放。调用方的 play/pause 自己负责刷新界面。
Future<void> kotvTogglePlayback({
  required bool playing,
  required Future<void> Function() play,
  required Future<void> Function() pause,
}) async {
  if (playing) {
    await pause();
  } else {
    await play();
  }
}

/// keep-open / 片尾态再点播放：应先回起点，避免只 unpause 停在末帧。
///
/// [completed] 为引擎 completed / eof；时长未知或 ≤1s 时只信 completed。
bool kotvShouldRestartFromEnd({
  required bool completed,
  required Duration position,
  required Duration duration,
}) {
  if (completed) return true;
  final durMs = duration.inMilliseconds;
  if (durMs <= 1000) return false;
  return position.inMilliseconds >= durMs - 350;
}

/// 片尾后再播：需要时先 [seekZero]，再 [play]。
Future<void> kotvPlayRestartingFromEndIfNeeded({
  required bool completed,
  required Duration position,
  required Duration duration,
  required Future<void> Function() seekZero,
  required Future<void> Function() play,
}) async {
  if (kotvShouldRestartFromEnd(
    completed: completed,
    position: position,
    duration: duration,
  )) {
    await seekZero();
  }
  await play();
}
