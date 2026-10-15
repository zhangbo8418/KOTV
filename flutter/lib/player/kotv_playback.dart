import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'keep_awake.dart';

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
  /// 原生 `setBufferingUi` / host bufferingPanel 已废弃，勿再扩。
  bool get preferNativeBufferingOverlay => false;
  /// 驱动原生缓冲浮层（仅 [preferNativeBufferingOverlay] 为 true 时有意义；已废弃）。
  Future<void> setNativeBufferingOverlay({required bool visible, required String text}) async {}
  /// 估算下载速度（字节/秒）；0 表示未知。
  int get networkSpeedBps => 0;
  double get volume; // 0–100
  double get rate;
  int get width;
  int get height;
  String get engineLabel;

  Stream<Duration> get positionStream;

  /// 缓冲位置变化（可选；UI 也可靠 [ChangeNotifier]）。
  Stream<Duration> get bufferedStream => const Stream<Duration>.empty();

  /// 本集自然播完（非手动 stop）时发出 true。
  Stream<bool> get completedStream;

  /// 最近一次播放错误文案；无错误为 null。播放中失败换线等可订阅 [addListener] 后读此字段。
  String? get lastError => null;

  /// [live]=true：直播页语境，跳过点播 KotvBufferBudget 预读。
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
  Future<void> playOrPause();
  Future<void> play();
  Future<void> pause();
  Future<void> stop();
  /// 换集停播：保留视频层（Surface/Texture），避免卸面闪烁与桌面卡音。
  Future<void> stopForEpisodeSwitch() => stop();
  Future<void> seek(Duration d);
  Future<void> setVolume(double v);
  Future<void> setRate(double r);
  Future<void> setRepeatOne(bool on);
  Future<void> setDecodeMode(String mode);

  /// Android Exo / 原生 MPV / FVP：Surface / Texture；其它后端忽略。
  Future<void> setRenderMode(String mode) async {}

  /// 后台「仅音频」时卸掉画面输出（音继续）；回前台再挂上。其它后端默认空实现。
  Future<void> setVideoOutputEnabled(bool enabled) async {}

  /// 画面比例：`default` 适应 / `fill` 拉伸 / `zoom` 裁切 / `16:9` / `4:3`。
  /// 原生 Surface 吃不到 Flutter BoxFit，需引擎侧落实；默认空实现。
  Future<void> setVideoScale(String mode) async {}

  /// 音量归一（loudnorm / dynaudnorm）；不支持的引擎忽略。
  Future<void> setStableVolume(bool on) async {}

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

  /// 外挂字幕文件（本地路径或 URL）；不支持的引擎忽略。
  Future<void> addSubtitleFile(String path, {String? title}) async {}

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

  /// 临时旁路画面/音频效果（按住看原画 / 试听原音）；松手后恢复。
  Future<void> setFxPreview({bool? videoOriginal, bool? audioOriginal}) async {}

  /// 查询设备 Equalizer 中心频率（Hz）；失败返回空。
  Future<List<int>> queryAudioEqCenters() async => const [];

  /// 离开详情/直播/切 Tab：拆掉原生播放器与 AO，避免后台漏音。
  ///
  /// **页面契约**：soft pause → `await release()` → 再清 `_playUrl` 卸宿主 →
  /// `dispose()` 包装类。`release()` 内须先停声并拆掉原生绑定。
  /// FVP Android Surface：引擎内先 `c.dispose()`（delete 前清 native surface 映射），
  /// 再摘 PlatformView。Texture / Exo / MPV：release 内或插件侧清面后即可删 player。
  /// 默认等同 [stop]；原生引擎应覆盖为 stop 后销毁实例。
  Future<void> release() => stop();

  /// Web 浏览器画中画；其它平台默认不支持。
  bool get supportsPictureInPicture => false;
  bool get pictureInPictureActive => false;
  void Function(bool active)? onPictureInPictureChanged;
  Future<bool> enterPictureInPicture() async => false;
  Future<void> exitPictureInPicture() async {}

  /// 播放或缓冲中保持屏幕常亮；暂停/停止/销毁时释放。
  void _syncKeepAwake() {
    final want = playing || stalling;
    if (_keepAwakeWant == want) return;
    _keepAwakeWant = want;
    KotvKeepAwake.setHolding(this, want);
  }

  @override
  void notifyListeners() {
    _syncKeepAwake();
    super.notifyListeners();
  }

  @override
  void dispose() {
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
/// 勿对会囤包缓存/解码缓冲的引擎设 [disposeTimeout]：超时把 dispose 丢后台会导致泄漏。
/// 调用方宜先 pause；本函数不改音量。
Future<void> kotvTeardownPlayback({
  required Future<void> Function() stop,
  required Future<void> Function() dispose,
  Duration drain = const Duration(milliseconds: 400),
  Duration? disposeTimeout,
}) async {
  try {
    await stop();
  } catch (_) {}
  await Future<void>.delayed(drain);
  final fut = dispose();
  try {
    if (disposeTimeout != null) {
      await fut.timeout(disposeTimeout);
    } else {
      await fut;
    }
  } on TimeoutException {
    // dispose 仍在跑；挂上 catch，避免未处理异步错误。
    unawaited(fut.catchError((_) {}));
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

/// 点播换集：对各后端 [KotvPlayback.stopForEpisodeSwitch]（FVP 会 dispose 缓冲）。
Future<void> kotvStopPlayersForEpisodeSwitch(Iterable<KotvPlayback?> players) async {
  Future<void> one(KotvPlayback? p) async {
    if (p == null) return;
    try {
      await p.stopForEpisodeSwitch();
    } catch (_) {}
  }

  await Future.wait<void>(players.map(one));
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
  const KotvTrack({required this.id, required this.label});
  final String id;
  final String label;
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

bool kotvSubtitleIsOff(String? id) {
  if (id == null) return true;
  switch (id.toLowerCase().trim()) {
    case '':
    case 'no':
    case 'none':
    case 'off':
      return true;
    default:
      return false;
  }
}

bool kotvSubtitleIsAuto(String? id) => (id ?? '').toLowerCase().trim() == 'auto';

bool kotvAudioIsAuto(String? id) {
  if (id == null || id.trim().isEmpty) return true;
  return id.toLowerCase().trim() == 'auto';
}

/// 设置项布尔：空串用 [def]；显式 false/off/0/no 为关，其余为开。
bool kotvSettingsFlag(Object? raw, {bool def = false}) {
  final t = '$raw'.trim().toLowerCase();
  if (t.isEmpty) return def;
  return t != 'false' && t != 'off' && t != '0' && t != 'no';
}

bool kotvSettingsMapFlag(Map<String, dynamic> settings, String key, {bool def = false}) {
  if (!settings.containsKey(key) || settings[key] == null) return def;
  return kotvSettingsFlag(settings[key], def: def);
}

/// MPV / FVP / Exo 开播后长时间无视频尺寸（有声无画或 Texture 0×0）。
class KotvSilentVideoException implements Exception {
  const KotvSilentVideoException([this.message = '播放器无画面']);
  final String message;
  @override
  String toString() => message;
}
