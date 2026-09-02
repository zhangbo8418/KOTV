import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'keep_awake.dart';

/// 统一播放后端：Exo / 原生 MPV / FVP / HTML 等共用同一套菜单/控件。
abstract class KotvPlayback extends ChangeNotifier {
  bool? _keepAwakeWant;

  bool get playing;
  bool get completed;
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
  /// Exo SurfaceView Hybrid Composition 下 Flutter 叠字会重影，改由原生画缓冲浮层。
  bool get preferNativeBufferingOverlay => false;
  /// 驱动原生缓冲浮层（仅 [preferNativeBufferingOverlay] 为 true 时有意义）。
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

  /// [live]=true：直播页语境（对齐 TV LiveActivity），跳过点播 KotvBufferBudget 预读。
  Future<void> open(
    String url, {
    Map<String, String>? headers,
    Map<String, dynamic>? drm,
    bool live = false,
  });
  Future<void> playOrPause();
  Future<void> play();
  Future<void> pause();
  Future<void> stop();
  Future<void> seek(Duration d);
  Future<void> setVolume(double v);
  Future<void> setRate(double r);
  Future<void> setRepeatOne(bool on);
  Future<void> setDecodeMode(String mode);

  /// Android Exo：Surface / Texture，对齐 TV 渲染方式。其它后端忽略。
  Future<void> setRenderMode(String mode) async {}

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
  /// 当前片源可切换的真实字幕轨（同上；关闭/自动请用 [setSubtitleTrack]）。
  List<KotvTrack> get subtitleTracks;
  String? get currentAudioId;
  String? get currentSubtitleId;
  Future<void> setAudioTrack(String id);
  Future<void> setSubtitleTrack(String id); // ''=关, 'auto'=自动

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

/// MPV / FVP / Exo 开播后长时间无视频尺寸（有声无画或 Texture 0×0）。
class KotvSilentVideoException implements Exception {
  const KotvSilentVideoException([this.message = '播放器无画面']);
  final String message;
  @override
  String toString() => message;
}
