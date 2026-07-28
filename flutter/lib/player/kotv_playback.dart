import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:kotv_vlc/kotv_vlc.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'kotv_vlc_paths.dart';

/// 统一播放后端：MPV(media_kit) 与 VLC(同进程 Texture) 共用同一套菜单/控件。
abstract class KotvPlayback extends ChangeNotifier {
  bool get playing;
  bool get completed;
  Duration get position;
  Duration get duration;
  double get volume; // 0–100
  double get rate;
  int get width;
  int get height;
  String get engineLabel;

  Stream<Duration> get positionStream;

  /// 本集自然播完（非手动 stop）时发出 true。
  Stream<bool> get completedStream;

  Future<void> open(String url);
  Future<void> playOrPause();
  Future<void> play();
  Future<void> pause();
  Future<void> stop();
  Future<void> seek(Duration d);
  Future<void> setVolume(double v);
  Future<void> setRate(double r);
  Future<void> setRepeatOne(bool on);
  Future<void> setDecodeMode(String mode);

  /// 当前片源可切换的真实音轨（不含 media_kit 注入的 `auto` / `no` 控制项）。
  List<KotvTrack> get audioTracks;
  /// 当前片源可切换的真实字幕轨（同上；关闭/自动请用 [setSubtitleTrack]）。
  List<KotvTrack> get subtitleTracks;
  String? get currentAudioId;
  String? get currentSubtitleId;
  Future<void> setAudioTrack(String id);
  Future<void> setSubtitleTrack(String id); // ''=关, 'auto'=自动
}

class KotvTrack {
  const KotvTrack({required this.id, required this.label});
  final String id;
  final String label;
}

/// media_kit 在解析 libmpv 的 `track-list` 时，会**先插入** [AudioTrack.auto]/[SubtitleTrack.no] 等
/// 控制项（见 media_kit `real.dart`），与 demuxer 里的真实轨混在同一列表；UI 应只读 [KotvPlayback.audioTracks]。
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

String _trackLabel(dynamic t) {
  if (t.title?.isNotEmpty == true) return t.title! as String;
  if (t.language?.isNotEmpty == true) return t.language! as String;
  return t.id as String;
}

/// media_kit / libmpv
class MediaKitPlayback extends KotvPlayback {
  MediaKitPlayback(this.player, {VideoController? controller})
      : controller = controller ?? VideoController(player) {
    _subs.add(player.stream.playing.listen((_) => notifyListeners()));
    _subs.add(player.stream.position.listen((_) => notifyListeners()));
    _subs.add(player.stream.duration.listen((_) => notifyListeners()));
    _subs.add(player.stream.width.listen((_) => notifyListeners()));
    _subs.add(player.stream.height.listen((_) => notifyListeners()));
    _subs.add(player.stream.volume.listen((_) => notifyListeners()));
    _subs.add(player.stream.rate.listen((_) => notifyListeners()));
    _subs.add(player.stream.completed.listen((_) => notifyListeners()));
  }

  final Player player;
  VideoController controller;
  final List<StreamSubscription> _subs = [];
  String _url = '';

  @override
  String get engineLabel => '内置 MPV';
  @override
  bool get playing => player.state.playing;
  @override
  bool get completed => player.state.completed;
  @override
  Duration get position => player.state.position;
  @override
  Duration get duration => player.state.duration;
  @override
  double get volume => player.state.volume.clamp(0, 100);
  @override
  double get rate => player.state.rate;
  @override
  int get width => player.state.width ?? controller.rect.value?.width.round() ?? 0;
  @override
  int get height => player.state.height ?? controller.rect.value?.height.round() ?? 0;
  @override
  Stream<Duration> get positionStream => player.stream.position;

  @override
  Stream<bool> get completedStream => player.stream.completed;

  @override
  Future<void> open(String url) async {
    _url = url;
    await player.open(Media(url));
  }

  @override
  Future<void> playOrPause() async => player.playOrPause();
  @override
  Future<void> play() async => player.play();
  @override
  Future<void> pause() async => player.pause();
  @override
  Future<void> stop() async => player.stop();
  @override
  Future<void> seek(Duration d) async => player.seek(d);
  @override
  Future<void> setVolume(double v) async => player.setVolume(v);
  @override
  Future<void> setRate(double r) async => player.setRate(r);
  @override
  Future<void> setRepeatOne(bool on) async =>
      player.setPlaylistMode(on ? PlaylistMode.single : PlaylistMode.none);

  @override
  Future<void> setDecodeMode(String mode) async {
    try {
      await (player.platform as dynamic).setProperty('hwdec', mode == 'soft' ? 'no' : 'auto');
    } catch (_) {}
    controller = VideoController(
      player,
      configuration: VideoControllerConfiguration(enableHardwareAcceleration: mode != 'soft'),
    );
    if (_url.isNotEmpty) {
      final pos = position;
      final wasPlaying = playing;
      await player.open(Media(_url));
      await player.seek(pos);
      if (wasPlaying) await player.play();
    }
    notifyListeners();
  }

  @override
  List<KotvTrack> get audioTracks => player.state.tracks.audio
      .where((t) => !kotvIsPseudoMediaTrack(t.id))
      .map((t) => KotvTrack(id: t.id, label: _trackLabel(t)))
      .toList();

  @override
  List<KotvTrack> get subtitleTracks => player.state.tracks.subtitle
      .where((t) => !kotvIsPseudoMediaTrack(t.id))
      .map((t) => KotvTrack(id: t.id, label: _trackLabel(t)))
      .toList();

  @override
  String? get currentAudioId => player.state.track.audio.id;
  @override
  String? get currentSubtitleId => player.state.track.subtitle.id;

  @override
  Future<void> setAudioTrack(String id) async {
    if (id == 'auto') {
      await player.setAudioTrack(AudioTrack.auto());
      return;
    }
    for (final t in player.state.tracks.audio) {
      if (t.id == id) {
        await player.setAudioTrack(t);
        return;
      }
    }
  }

  @override
  Future<void> setSubtitleTrack(String id) async {
    if (id.isEmpty) {
      await player.setSubtitleTrack(SubtitleTrack.no());
      return;
    }
    if (id == 'auto') {
      await player.setSubtitleTrack(SubtitleTrack.auto());
      return;
    }
    for (final t in player.state.tracks.subtitle) {
      if (t.id == id) {
        await player.setSubtitleTrack(t);
        return;
      }
    }
  }

  @override
  void dispose() {
    for (final s in _subs) {
      s.cancel();
    }
    super.dispose();
  }
}

/// 同进程 libvlc Texture 直出（与 media_kit/mpv 同类）；失败直接抛错，不回落。
class EngineVlcPlayback extends KotvPlayback {
  EngineVlcPlayback() {
    if (!KotvVlc.isSupported) {
      throw UnsupportedError('内置 VLC Texture 仅支持桌面（macOS / Windows / Linux）');
    }
    _native = KotvVlc();
  }

  late final KotvVlc _native;
  final _posCtrl = StreamController<Duration>.broadcast();
  final _endedCtrl = StreamController<bool>.broadcast();
  Timer? _statusTimer;
  String _url = '';
  String _decodeMode = 'auto';
  bool _playing = false;
  bool _ended = false;
  int _positionMs = 0;
  int _durationMs = 0;
  int _volume = 80;
  double _rate = 1.0;
  int _videoW = 0;
  int _videoH = 0;
  bool _ready = false;

  bool get useTexture => _ready && _native.textureId != null && _native.textureId! >= 0;
  int? get textureId => _native.textureId;

  Future<void> _tickNativeStatus() async {
    try {
      final st = await _native.status();
      final wasEnded = _ended;
      _playing = st['playing'] == true;
      _positionMs = (st['positionMs'] as num?)?.toInt() ?? _positionMs;
      _durationMs = (st['durationMs'] as num?)?.toInt() ?? _durationMs;
      _videoW = (st['width'] as num?)?.toInt() ?? _videoW;
      _videoH = (st['height'] as num?)?.toInt() ?? _videoH;
      if (st['rate'] is num) _rate = (st['rate'] as num).toDouble();
      // VLC 无统一 completed 事件：近片尾且停播视为本集结束
      if (_durationMs > 1500 && !_playing && _positionMs >= _durationMs - 1200) {
        _ended = true;
      } else if (_playing) {
        _ended = false;
      }
      if (!_posCtrl.isClosed) _posCtrl.add(Duration(milliseconds: _positionMs));
      if (_ended && !wasEnded && !_endedCtrl.isClosed) {
        _endedCtrl.add(true);
      }
      notifyListeners();
    } catch (_) {}
  }

  @override
  String get engineLabel => '内置 VLC';
  @override
  bool get playing => _playing;
  @override
  bool get completed => _ended;
  @override
  Duration get position => Duration(milliseconds: _positionMs);
  @override
  Duration get duration => Duration(milliseconds: _durationMs);
  @override
  double get volume => _volume.toDouble();
  @override
  double get rate => _rate;
  @override
  int get width => _videoW;
  @override
  int get height => _videoH;
  @override
  Stream<Duration> get positionStream => _posCtrl.stream;

  @override
  Stream<bool> get completedStream => _endedCtrl.stream;

  @override
  Future<void> open(String url) async {
    _url = url;
    _ended = false;
    final libDir = KotvVlcPaths.resolveLibDir();
    if (libDir == null) throw StateError('未找到 runtime/libvlc');
    await _native.create();
    await _native.load(libDir: libDir, pluginDir: KotvVlcPaths.pluginDirFor(libDir));
    await _native.setDecodeMode(_decodeMode);
    await _native.play(url);
    _ready = true;
    _statusTimer?.cancel();
    _statusTimer = Timer.periodic(const Duration(milliseconds: 250), (_) => unawaited(_tickNativeStatus()));
    await _tickNativeStatus();
    notifyListeners();
  }

  @override
  Future<void> playOrPause() async {
    final m = await _native.toggle();
    _playing = m['playing'] == true;
    notifyListeners();
  }

  @override
  Future<void> play() async {
    await _native.resume();
    _playing = true;
    notifyListeners();
  }

  @override
  Future<void> pause() async {
    await _native.pause();
    _playing = false;
    notifyListeners();
  }

  @override
  Future<void> stop() async {
    await _native.stop();
    _playing = false;
    _positionMs = 0;
    notifyListeners();
  }

  @override
  Future<void> seek(Duration d) async {
    await _native.seekMs(d.inMilliseconds);
    _positionMs = d.inMilliseconds;
    notifyListeners();
  }

  @override
  Future<void> setVolume(double v) async {
    _volume = v.round().clamp(0, 100);
    await _native.setVolume(_volume);
    notifyListeners();
  }

  @override
  Future<void> setRate(double r) async {
    _rate = r;
    await _native.setRate(r);
    notifyListeners();
  }

  @override
  Future<void> setRepeatOne(bool on) async {}

  @override
  Future<void> setDecodeMode(String mode) async {
    _decodeMode = mode;
    if (!_ready) return; // open() 会带上当前模式
    await _native.setDecodeMode(mode);
    // media 选项需重建才生效
    if (_url.isNotEmpty) {
      final pos = position;
      final wasPlaying = playing;
      await _native.play(_url);
      if (pos > Duration.zero) await seek(pos);
      if (!wasPlaying) await pause();
    }
  }

  @override
  List<KotvTrack> get audioTracks => const [];
  @override
  List<KotvTrack> get subtitleTracks => const [];
  @override
  String? get currentAudioId => null;
  @override
  String? get currentSubtitleId => null;
  @override
  Future<void> setAudioTrack(String id) async {}
  @override
  Future<void> setSubtitleTrack(String id) async {}

  @override
  void dispose() {
    _statusTimer?.cancel();
    unawaited(_native.dispose());
    _posCtrl.close();
    _endedCtrl.close();
    super.dispose();
  }
}
