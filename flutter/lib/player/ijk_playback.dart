import 'dart:async';

import 'package:fijkplayer/fijkplayer.dart';
import 'package:flutter/material.dart';

import 'kotv_playback.dart';
import 'kotv_platform.dart';
import 'buffer_budget.dart';
import 'play_headers.dart';

/// Android ijkplayer：对齐 Exo 的 headers / 代理 / 软硬解策略。
///
/// 软硬解映射 bilibili ijk 选项（须在 setDataSource 前 setOption）：
/// - hard：mediacodec + avc/hevc/all-videos
/// - soft：全部 mediacodec* = 0（走 FFmpeg）
/// - auto：开硬解，失败由 ijk 内部回落软解
class IjkPlayback extends KotvPlayback {
  IjkPlayback() {
    if (!kotvIsAndroid()) {
      throw UnsupportedError('内置 ijk 仅支持 Android');
    }
    _player = FijkPlayer();
    _player.addListener(_onUpdate);
  }

  late final FijkPlayer _player;
  final _posCtrl = StreamController<Duration>.broadcast();
  final _endedCtrl = StreamController<bool>.broadcast();
  Timer? _tick;
  String _url = '';
  Map<String, String> _headers = const {};
  bool _playing = false;
  bool _completed = false;
  bool _buffering = false;
  int _speedBps = 0;
  int _lastTrafficBytes = 0;
  DateTime? _lastTrafficAt;
  int _lastPosMs = -1;
  DateTime? _lastPosAt;
  bool _stalled = false;
  bool _speedBusy = false;
  double _volume = 80;
  double _rate = 1;
  int _w = 0;
  int _h = 0;
  bool _repeatOne = false;
  String _decodeMode = 'auto';

  FijkPlayer get player => _player;

  @override
  String get engineLabel => '内置 ijk';
  @override
  bool get playing => _playing;
  @override
  bool get completed => _completed;
  @override
  Duration get position => Duration(milliseconds: _player.currentPos.inMilliseconds);
  @override
  Duration get duration => _player.value.duration;
  @override
  Duration get buffered => _player.bufferPos;
  @override
  bool get buffering => _buffering || _stalled;
  @override
  int get networkSpeedBps => _speedBps;

  @override
  double get volume => _volume;
  @override
  double get rate => _rate;
  @override
  int get width => _w;
  @override
  int get height => _h;
  @override
  Stream<Duration> get positionStream => _posCtrl.stream;
  @override
  Stream<Duration> get bufferedStream => _player.onBufferPosUpdate;
  @override
  Stream<bool> get completedStream => _endedCtrl.stream;

  Widget buildView({BoxFit fit = BoxFit.contain}) {
    return FijkView(
      player: _player,
      fit: _mapFit(fit),
      color: Colors.black,
      panelBuilder: (_, __, ___, ____, _____) => const SizedBox.shrink(),
    );
  }

  FijkFit _mapFit(BoxFit fit) {
    switch (fit) {
      case BoxFit.cover:
        return FijkFit.cover;
      case BoxFit.fill:
        return FijkFit.fill;
      case BoxFit.fitWidth:
        return FijkFit.fitWidth;
      case BoxFit.fitHeight:
        return FijkFit.fitHeight;
      default:
        return FijkFit.contain;
    }
  }

  void _onUpdate() {
    final st = _player.state;
    _playing = st == FijkState.started;
    _buffering = st == FijkState.asyncPreparing || _player.isBuffering;
    final size = _player.value.size;
    if (size != null) {
      _w = size.width.toInt();
      _h = size.height.toInt();
    }
    if (!_posCtrl.isClosed) {
      _posCtrl.add(Duration(milliseconds: _player.currentPos.inMilliseconds));
    }
    if (st == FijkState.completed && !_completed) {
      _completed = true;
      if (!_endedCtrl.isClosed) _endedCtrl.add(true);
      if (_repeatOne && _url.isNotEmpty) {
        unawaited(open(_url, headers: _headers));
      }
    } else if (_playing) {
      _completed = false;
    }
    notifyListeners();
  }

  String _normalizeDecode(String mode) {
    final m = mode.trim().toLowerCase();
    return switch (m) {
      'soft' || 'software' || 'sw' => 'soft',
      'hard' || 'hardware' || 'hw' => 'hard',
      _ => 'auto',
    };
  }

  Future<void> _applyDecodeOptions() async {
    final soft = _decodeMode == 'soft';
    // soft=0；hard/auto=1（auto 依赖 ijk 硬解失败回落软解）
    final mc = soft ? 0 : 1;
    await _player.setOption(FijkOption.playerCategory, 'mediacodec', mc);
    await _player.setOption(FijkOption.playerCategory, 'mediacodec-avc', mc);
    await _player.setOption(FijkOption.playerCategory, 'mediacodec-hevc', mc);
    await _player.setOption(FijkOption.playerCategory, 'mediacodec-mpeg2', mc);
    await _player.setOption(FijkOption.playerCategory, 'mediacodec-mpeg4', mc);
    await _player.setOption(FijkOption.playerCategory, 'mediacodec-all-videos', mc);
    await _player.setOption(FijkOption.playerCategory, 'mediacodec-auto-rotate', mc);
    await _player.setOption(FijkOption.playerCategory, 'mediacodec-handle-resolution-change', mc);
    // 硬解同步（部分机型黑屏可关）；软解无关
    await _player.setOption(FijkOption.playerCategory, 'mediacodec-sync', soft ? 0 : 1);
    // 申请音频焦点；OpenSL ES 在多数机型更稳（AudioTrack 易无声）
    await _player.setOption(FijkOption.hostCategory, 'request-audio-focus', 1);
    await _player.setOption(FijkOption.hostCategory, 'release-audio-focus', 1);
    await _player.setOption(FijkOption.hostCategory, 'request-screen-on', 1);
    await _player.setOption(FijkOption.playerCategory, 'opensles', 1);
    await _player.setOption(FijkOption.playerCategory, 'mediacodec-audio', 0);
    await _player.setOption(FijkOption.playerCategory, 'framedrop', 1);
    await _player.setOption(FijkOption.playerCategory, 'start-on-prepared', 1);
    await _player.setOption(FijkOption.playerCategory, 'packet-buffering', 1);
    await KotvBufferBudget.warm();
    final budget = KotvBufferBudget.bytes();
    // 内存水位：max-buffer-size 为上限；infbuf=1 不按时长停拉；播完的包释放后继续补满
    await _player.setOption(FijkOption.playerCategory, 'max-buffer-size', budget);
    await _player.setOption(FijkOption.playerCategory, 'infbuf', 1);
    await _player.setOption(FijkOption.playerCategory, 'min-frames', 25);
    await _player.setOption(FijkOption.formatCategory, 'analyzeduration', 1);
    await _player.setOption(FijkOption.formatCategory, 'analyzemaxduration', 100);
    await _player.setOption(FijkOption.formatCategory, 'probesize', 10240);
    await _player.setOption(FijkOption.formatCategory, 'flush_packets', 1);
    await _player.setOption(FijkOption.formatCategory, 'http-detect-range-support', 0);
    await _player.setOption(FijkOption.formatCategory, 'fflags', 'fastseek');
    await _player.setOption(FijkOption.codecCategory, 'skip_loop_filter', soft ? 0 : 48);
  }

  Future<void> _applyHeaders() async {
    if (_headers.isEmpty) return;
    final ua = _headers['User-Agent'];
    if (ua != null && ua.isNotEmpty) {
      await _player.setOption(FijkOption.formatCategory, 'user_agent', ua);
    }
    final hdr = kotvHeadersToIjkFormat(_headers);
    if (hdr.isNotEmpty) {
      await _player.setOption(FijkOption.formatCategory, 'headers', hdr);
    }
  }

  @override
  Future<void> open(String url, {Map<String, String>? headers, Map<String, dynamic>? drm}) async {
    if (drm != null && '${drm['type'] ?? ''}'.trim().isNotEmpty) {
      throw UnsupportedError('DRM 内容请使用内置 ExoPlayer');
    }
    _url = url;
    _headers = kotvNormalizePlayHeaders(headers, url: url);
    _completed = false;
    _speedBps = 0;
    _lastTrafficBytes = 0;
    _lastTrafficAt = null;
    _lastPosMs = -1;
    _lastPosAt = null;
    _stalled = false;
    await _player.reset();
    // setOption 必须在 setDataSource 之前
    await _applyDecodeOptions();
    await _applyHeaders();
    await _player.setDataSource(url, autoPlay: true);
    await _player.setVolume(_volume / 100.0);
    if (_rate != 1.0) await _player.setSpeed(_rate);
    _tick?.cancel();
    _tick = Timer.periodic(const Duration(milliseconds: 400), (_) {
      if (_posCtrl.isClosed) return;
      _posCtrl.add(Duration(milliseconds: _player.currentPos.inMilliseconds));
      final wasStalled = _stalled;
      _trackStall();
      if (wasStalled != _stalled) notifyListeners();
      unawaited(_pollSpeed());
    });
    notifyListeners();
  }

  Future<void> _pollSpeed() async {
    if (_speedBusy) return;
    _speedBusy = true;
    try {
      var next = 0;
      var sampled = false;
      try {
        final traffic = await _player.getTrafficStatisticByteCount();
        final now = DateTime.now();
        final prevAt = _lastTrafficAt;
        final prevBytes = _lastTrafficBytes;
        if (prevAt != null) {
          final dtMs = now.difference(prevAt).inMilliseconds;
          if (dtMs >= 200) {
            if (traffic >= prevBytes) {
              // 有增长才有速度；持平/停滞必须归 0，否则会黏在上一帧
              final delta = traffic - prevBytes;
              next = delta > 0 ? (((delta * 1000) / dtMs).round().clamp(0, 1 << 30)) : 0;
            } else {
              // seek/重开导致计数回绕：重置基准，本帧先显示 0
              next = 0;
            }
            sampled = true;
            _lastTrafficBytes = traffic;
            _lastTrafficAt = now;
          }
        } else {
          // 建基线；瞬时 tcp 速度可垫第一帧（对齐 TV 起播就有数）
          _lastTrafficBytes = traffic;
          _lastTrafficAt = now;
          sampled = false;
          next = 0;
        }
      } catch (_) {}
      // 尚无差分样本时用 getTcpSpeed 垫一帧
      if (!sampled) {
        try {
          final tcp = await _player.getTcpSpeed();
          if (tcp > 0) next = tcp;
        } catch (_) {}
      }
      final changed = next != _speedBps;
      _speedBps = next;
      if (changed || _buffering || _stalled) {
        notifyListeners();
      }
    } finally {
      _speedBusy = false;
    }
  }

  /// ijk 的 freeze 事件并不总会来：播放中进度长时间不前进也算卡住，
  /// 这样浮层才会亮出网速，让用户能判断线路是不是死了。
  void _trackStall() {
    final posMs = _player.currentPos.inMilliseconds;
    final now = DateTime.now();
    if (posMs != _lastPosMs) {
      _lastPosMs = posMs;
      _lastPosAt = now;
      _stalled = false;
      return;
    }
    if (!_playing) {
      _lastPosAt = now;
      _stalled = false;
      return;
    }
    final since = _lastPosAt;
    _stalled = since != null && now.difference(since) > const Duration(milliseconds: 1200);
  }

  @override
  Future<void> playOrPause() async {
    if (_playing) {
      await _player.pause();
    } else {
      await _player.start();
    }
  }

  @override
  Future<void> play() async => _player.start();
  @override
  Future<void> pause() async => _player.pause();
  @override
  Future<void> stop() async => _player.stop();

  @override
  Future<void> seek(Duration d) async => _player.seekTo(d.inMilliseconds);

  @override
  Future<void> setVolume(double v) async {
    _volume = v.clamp(0, 100);
    await _player.setVolume(_volume / 100.0);
    notifyListeners();
  }

  @override
  Future<void> setRate(double r) async {
    _rate = r.clamp(0.25, 4.0);
    await _player.setSpeed(_rate);
    notifyListeners();
  }

  @override
  Future<void> setRepeatOne(bool on) async {
    _repeatOne = on;
  }

  @override
  Future<void> setDecodeMode(String mode) async {
    final next = _normalizeDecode(mode);
    if (next == _decodeMode && _url.isEmpty) return;
    final pos = position;
    final wasPlaying = _playing;
    _decodeMode = next;
    if (_url.isEmpty) {
      notifyListeners();
      return;
    }
    // ijk 选项仅在 open 前生效：保留进度重开
    await open(_url, headers: _headers);
    if (pos > Duration.zero) {
      try {
        await seek(pos);
      } catch (_) {}
    }
    if (!wasPlaying) {
      try {
        await pause();
      } catch (_) {}
    }
    notifyListeners();
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
    _tick?.cancel();
    _player.removeListener(_onUpdate);
    _player.release();
    _posCtrl.close();
    _endedCtrl.close();
    super.dispose();
  }
}
