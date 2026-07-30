import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:window_manager/window_manager.dart';

import '../desktop/mini_player_window.dart';
import '../models/models.dart';
import '../player/danmaku_layer.dart';
import '../player/embed_video_view.dart';
import '../player/kotv_platform.dart';
import '../player/kotv_playback.dart';
import '../providers.dart';
import '../remote/local_collect.dart';
import '../remote/postmsg_host.dart';
import '../remote/remote_bridge.dart';
import '../theme/layout_scale.dart';
import '../theme/kotv_theme.dart';
import '../widgets/cast_flow.dart';
import '../widgets/chrome.dart';
import '../widgets/mini_hover_shell.dart';
import '../widgets/vod_player_chrome.dart';
import 'detail_fullscreen.dart';
import 'shell.dart';

class DetailScreen extends ConsumerStatefulWidget {
  const DetailScreen({super.key, required this.id, this.site = '', this.title = ''});

  final String id;
  final String site;
  final String title;

  /// 换源等场景：在 pop 详情栈前先硬停播（await），避免后台继续出声。
  static Future<void> prepareLeave() async {
    final active = _DetailScreenState._active;
    if (active == null) return;
    await active._stopHard();
    if (!active.mounted) return;
    // 放开 PopScope，否则随后的 popUntil 会被 canPop:false 拦住。
    active._allowPop = true;
    active.setState(() {});
    await WidgetsBinding.instance.endOfFrame;
  }

  @override
  ConsumerState<DetailScreen> createState() => _DetailScreenState();
}

class _DetailScreenState extends ConsumerState<DetailScreen> {
  static _DetailScreenState? _active;
  VodDetail? _detail;
  String? _error;
  bool _loading = true;
  int _flagIdx = 0;
  int _epIdx = -1;
  int _epPage = 0;
  bool _reversed = false;
  bool _kept = false;
  String _status = '选择剧集开始播放';
  String _playUrl = '';
  String _decodeMode = 'auto';
  bool _danmakuOn = false;
  bool _ambientOn = false;
  bool _stableVolumeOn = false;
  String _danmakuApi = '';
  final ValueNotifier<List<DanmakuItem>> _danmakuItems = ValueNotifier(const []);
  AspectSpec _aspect = const AspectSpec(key: 'default', fit: BoxFit.contain);
  int _openingSec = 0;
  int _endingSec = 0;
  String _playerVal = kotvIsWindows7() ? 'innie#vlc' : 'innie#mpv';
  bool _miniDesktop = false;
  static const _epSize = 20;

  Player? _mkPlayer;
  MediaKitPlayback? _mk;
  EngineVlcPlayback? _vlc;
  StreamSubscription? _playingSub;
  StreamSubscription? _endedSub;
  StreamSubscription<Duration>? _posSub;
  bool _autoNextArmed = true;
  bool _openingSeekDone = false;
  bool _endingSkipFired = false;
  bool _stoppedHard = false;
  /// 硬停完成后再允许真正出栈（配合 [PopScope]）。
  bool _allowPop = false;
  /// 开播后短时间内忽略 completed，避免 stop 后残留 completed=true 立刻触发下一集/停播。
  DateTime? _playArmedAt;

  /// 当前页内后端：默认 MPV；手动选 VLC 时共用同一套控件。
  KotvPlayback get _playback => _useVlc ? (_vlc ??= EngineVlcPlayback()) : _ensureMpv();
  bool get _useVlc => _playerVal.trim() == 'innie#vlc';

  MediaKitPlayback _ensureMpv() {
    if (_mk != null) {
      // stopHard 会拆掉 playing 订阅；复用 Player 时必须重新挂上。
      _playingSub ??= _mkPlayer!.stream.playing.listen((playing) {
        if (!mounted || _playUrl.isEmpty || _useVlc) return;
        setState(() {
          if (playing) {
            _status = '内置 MPV 播放中';
          } else if (_mkPlayer!.state.completed) {
            _status = '播放结束';
          } else {
            _status = '已暂停';
          }
        });
      });
      return _mk!;
    }
    final player = Player();
    _mkPlayer = player;
    _mk = MediaKitPlayback(player);
    _playingSub = player.stream.playing.listen((playing) {
      if (!mounted || _playUrl.isEmpty || _useVlc) return;
      setState(() {
        if (playing) {
          _status = '内置 MPV 播放中';
        } else if (player.state.completed) {
          _status = '播放结束';
        } else {
          _status = '已暂停';
        }
      });
    });
    _wireEnded(_mk!);
    _wirePosition(_mk!);
    return _mk!;
  }

  @override
  void initState() {
    super.initState();
    _active = this;
    _load();
  }

  /// await stop，等原生停住（Win7 上 unawaited stop 不够）。
  /// 不要 pause/静音：pause 会粘在播放器上，下次 open 只出一帧；静音会带到下一集。
  Future<void> _stopHard() async {
    _autoNextArmed = false;
    _playingSub?.cancel();
    _endedSub?.cancel();
    _posSub?.cancel();
    _playingSub = null;
    _endedSub = null;
    _posSub = null;
    _playUrl = '';

    Future<void> hardStop(KotvPlayback? p) async {
      if (p == null) return;
      try {
        await p.stop();
      } catch (_) {}
    }

    await Future.wait<void>([
      hardStop(_vlc),
      hardStop(_mk),
    ]);
    _stoppedHard = true;
  }

  Future<void> _leavePage({VoidCallback? afterPop}) async {
    if (_miniDesktop) {
      try {
        await _exitMini();
      } catch (_) {}
    }
    await _stopHard();
    if (!mounted) return;
    _allowPop = true;
    setState(() {});
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    Navigator.of(context).pop();
    afterPop?.call();
  }

  void _wireEnded(KotvPlayback p) {
    _endedSub?.cancel();
    _endedSub = p.completedStream.listen((done) {
      if (!done || !mounted) return;
      unawaited(_onPlaybackEnded());
    });
  }

  void _wirePosition(KotvPlayback p) {
    _posSub?.cancel();
    _posSub = p.positionStream.listen(_onPositionTick);
  }

  /// 对齐 TV：片头起播跳过；片尾 `ending+position>=duration` 切下一集。
  void _onPositionTick(Duration pos) {
    if (_playUrl.isEmpty || !mounted) return;
    final dur = _playback.duration;
    if (dur.inMilliseconds <= 0) return;
    final openMs = _openingSec * 1000;
    final endMs = _endingSec * 1000;
    if (openMs > 0 && !_openingSeekDone) {
      if (pos.inMilliseconds + 800 < openMs) {
        _openingSeekDone = true;
        unawaited(_playback.seek(Duration(milliseconds: openMs)));
        return;
      }
      if (pos.inMilliseconds >= openMs) _openingSeekDone = true;
    }
    if (endMs > 0 && pos.inMilliseconds + endMs >= dur.inMilliseconds) {
      if (!_endingSkipFired) {
        _endingSkipFired = true;
        _openingSeekDone = false;
        unawaited(_playAt(_epIdx + 1));
      }
    } else {
      _endingSkipFired = false;
    }
  }

  Future<void> _onPlaybackEnded() async {
    final armed = _playArmedAt;
    if (armed != null && DateTime.now().difference(armed) < const Duration(seconds: 2)) {
      return;
    }
    if (!_autoNextArmed || _playUrl.isEmpty) return;
    final eps = _eps;
    final next = _epIdx + 1;
    if (next < 0 || next >= eps.length) {
      if (mounted) setState(() => _status = '播放结束');
      return;
    }
    _autoNextArmed = false;
    if (mounted) setState(() => _status = '自动播放下一集…');
    try {
      await _playAt(next);
    } finally {
      _autoNextArmed = true;
    }
  }

  @override
  void dispose() {
    if (_active == this) _active = null;
    // 离开详情：回传扫码取消并打断 JAR；不要再 nav.pop（本页正在出栈）。
    final api = ref.read(apiProvider);
    unawaited(PostMsgHost.instance?.cancelAll(reply: true, popDialog: false) ?? Future<void>.value());
    unawaited(api.cancelPending());
    if (_miniDesktop) {
      unawaited(MiniPlayerWindow.exit());
    }
    _playingSub?.cancel();
    _endedSub?.cancel();
    _posSub?.cancel();
    _danmakuItems.dispose();
    // 正常路径已在 [_stopHard] 里 await pause/stop；此处兜底再停一次再释放。
    if (!_stoppedHard) {
      unawaited(_vlc?.stop() ?? Future<void>.value());
      unawaited(_mk?.stop() ?? Future<void>.value());
    }
    _vlc?.dispose();
    _mk?.dispose();
    _mkPlayer?.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final data = await ref.read(apiProvider).detail(id: widget.id, site: widget.site);
      final vod = VodDetail.fromJson(Map<String, dynamic>.from(data['vod'] as Map));
      final kept = await LocalCollect.isKept(
        vod.id.isNotEmpty ? vod.id : widget.id,
        vod.site.isNotEmpty ? vod.site : widget.site,
      );
      try {
        final st = await ref.read(apiProvider).getSettings();
        final settings = Map<String, dynamic>.from((st['settings'] as Map?) ?? const {});
        final decode = '${settings['playerDecode'] ?? 'auto'}';
        if (decode.isNotEmpty) _decodeMode = decode;
        _danmakuOn = '${settings['danmaku'] ?? ''}'.toLowerCase() == 'true';
        _ambientOn = '${settings['playerAmbient'] ?? ''}'.toLowerCase() == 'true';
        _stableVolumeOn = '${settings['playerStableVolume'] ?? ''}'.toLowerCase() == 'true';
        _danmakuApi = '${settings['danmakuApi'] ?? ''}';
        final scale = '${settings['playerScale'] ?? 'default'}';
        _aspect = _aspectFromScale(scale);
        var playerVal = '${settings['player'] ?? (kotvIsWindows7() ? 'innie#vlc' : 'innie#mpv')}'.trim();
        if (playerVal.isEmpty) {
          playerVal = kotvIsWindows7() ? 'innie#vlc' : 'innie#mpv';
        }
        _playerVal = playerVal;
        // 未开播前不创建 media_kit Player（Win7 上进详情即创建易卡 UI）；真正点播时再 _ensureMpv。
        if (!_useVlc && !kotvIsWindows7()) {
          final mk = _ensureMpv();
          final speed = double.tryParse('${settings['playerSpeed'] ?? ''}');
          if (speed != null && speed > 0) await mk.setRate(speed);
          final vol = double.tryParse('${settings['playerVolume'] ?? ''}');
          if (vol != null) await mk.setVolume(vol.clamp(0, 100));
          if (_stableVolumeOn) {
            await _applyStableVolume(mk, true);
          }
        }
      } catch (_) {}
      setState(() {
        _detail = vod;
        _kept = kept;
        _loading = false;
      });
      final id = vod.id.isNotEmpty ? vod.id : widget.id;
      final site = vod.site.isNotEmpty ? vod.site : widget.site;
      final off = await LocalPlayOffsets.get(id, site);
      if (mounted) {
        setState(() {
          _openingSec = off.$1;
          _endingSec = off.$2;
        });
      }
    } catch (e) {
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  List<EpisodeItem> get _eps {
    final d = _detail;
    if (d == null || d.flags.isEmpty) return const [];
    final flag = d.flags[_flagIdx.clamp(0, d.flags.length - 1)];
    final list = List<EpisodeItem>.from(flag.episodes);
    return _reversed ? list.reversed.toList() : list;
  }

  AspectSpec _aspectFromScale(String scale) {
    switch (scale) {
      case 'fill':
        return const AspectSpec(key: 'fill', fit: BoxFit.fill);
      case 'zoom':
        return const AspectSpec(key: 'zoom', fit: BoxFit.cover);
      case '16:9':
        return const AspectSpec(key: '16:9', fit: BoxFit.fill, ratio: 16 / 9);
      case '4:3':
        return const AspectSpec(key: '4:3', fit: BoxFit.fill, ratio: 4 / 3);
      default:
        return const AspectSpec(key: 'default', fit: BoxFit.contain);
    }
  }

  Future<void> _applyStableVolume(KotvPlayback p, bool on) async {
    if (p is MediaKitPlayback) {
      try {
        await (p.player.platform as dynamic).setProperty('af', on ? 'loudnorm' : '');
      } catch (_) {
        try {
          await (p.player.platform as dynamic).setProperty('af', on ? 'dynaudnorm' : '');
        } catch (_) {}
      }
      return;
    }
    if (p is EngineVlcPlayback) {
      await p.setStableVolume(on);
    }
  }

  Future<void> _loadDanmakuForEpisode({
    required String playDanmaku,
    required String name,
    required String episode,
  }) async {
    _danmakuItems.value = const [];
    if (playDanmaku.trim().isEmpty && _danmakuApi.trim().isEmpty) return;
    try {
      List<DanmakuItem> items = const [];
      if (playDanmaku.trim().isNotEmpty) {
        items = await DanmakuLoader.loadUrl(playDanmaku);
      }
      if (items.isEmpty && _danmakuApi.trim().isNotEmpty) {
        items = await DanmakuLoader.loadApi(_danmakuApi, name: name, episode: episode);
      }
      if (!mounted) return;
      _danmakuItems.value = items;
    } catch (_) {
      if (mounted) _danmakuItems.value = const [];
    }
  }

  Future<void> _playAt(int epIdx, {bool fullscreen = false}) async {
    final d = _detail;
    if (d == null || d.flags.isEmpty) return;
    final flag = d.flags[_flagIdx.clamp(0, d.flags.length - 1)];
    final eps = _eps;
    if (epIdx < 0 || epIdx >= eps.length) return;
    final ep = eps[epIdx];
    _stoppedHard = false;
    _autoNextArmed = true;
    setState(() {
      _epIdx = epIdx;
      _status = '解析中…';
    });
    try {
      final data = await ref.read(apiProvider).play(
            url: ep.url,
            site: d.site.isNotEmpty ? d.site : widget.site,
            id: widget.id,
            flag: flag.flag,
          );
      final playUrl = '${data['url'] ?? ''}';
      if (playUrl.isEmpty) throw Exception('空播放地址');
      await LocalHistory.push(VodItem(
        id: d.id.isNotEmpty ? d.id : widget.id,
        name: d.name,
        pic: d.pic,
        site: d.site,
        remarks: ep.name,
      ));
      if (_useVlc) {
        try {
          await _mk?.stop();
        } catch (_) {}
        _vlc ??= EngineVlcPlayback();
        await _vlc!.setDecodeMode(_decodeMode);
        await _vlc!.open(playUrl);
        try {
          await _vlc!.play();
        } catch (_) {}
        if (_stableVolumeOn) await _applyStableVolume(_vlc!, true);
        if (!mounted) return;
        setState(() {
          _playUrl = playUrl;
          _status = '内置 VLC 播放中';
        });
      } else {
        try {
          await _vlc?.stop();
        } catch (_) {}
        final mk = _ensureMpv();
        await mk.open(playUrl);
        // stop/pause 后 media_kit 可能仍处暂停态，显式 play 避免只出一帧。
        try {
          await mk.play();
        } catch (_) {}
        if (_stableVolumeOn) await _applyStableVolume(mk, true);
        if (!mounted) return;
        setState(() {
          _playUrl = playUrl;
          _status = '内置 MPV 播放中';
        });
      }
      unawaited(_loadDanmakuForEpisode(
        playDanmaku: '${data['danmaku'] ?? ''}',
        name: d.name,
        episode: ep.name,
      ));
      _wireEnded(_playback);
      _wirePosition(_playback);
      _openingSeekDone = false;
      _endingSkipFired = false;
      _autoNextArmed = true;
      _playArmedAt = DateTime.now();
      ref.read(remoteBridgeProvider)?.reportMedia(state: 'playing', title: '${d.name} · ${ep.name}', url: playUrl);
      if (fullscreen && mounted) {
        await _enterFullscreen();
      }
    } catch (e) {
      setState(() {
        _playUrl = '';
        _status = '播放失败: $e';
      });
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  Future<void> _enterFullscreen() async {
    final d = _detail;
    if (d == null || !mounted) return;
    if (_miniDesktop) await _exitMini();
    final eps = _eps;
    final api = ref.read(apiProvider);
    final id = d.id.isNotEmpty ? d.id : widget.id;
    final site = d.site.isNotEmpty ? d.site : widget.site;
    final title = '${d.name}${_epIdx >= 0 && _epIdx < eps.length ? ' · ${eps[_epIdx].name}' : ''}';

    await Navigator.of(context).push(
      PageRouteBuilder(
        opaque: true,
        pageBuilder: (_, __, ___) => ValueListenableBuilder<List<DanmakuItem>>(
          valueListenable: _danmakuItems,
          builder: (context, danmakuItems, _) => DetailFullscreenPage(
          playback: _playback,
          vodName: d.name,
          title: title,
          episodes: eps.map((e) => e.name).toList(),
          epIdx: _epIdx,
          playUrl: _playUrl,
          decodeMode: _decodeMode,
          aspect: _aspect,
          danmakuOn: _danmakuOn,
          danmakuItems: danmakuItems,
          ambientOn: _ambientOn,
          stableVolumeOn: _stableVolumeOn,
          keepLabel: _kept ? '取消收藏' : '收藏',
          offsetId: id,
          offsetSite: site,
          openingSec: _openingSec,
          endingSec: _endingSec,
          onOffsetsChanged: (open, end) {
            if (!mounted) return;
            setState(() {
              _openingSec = open;
              _endingSec = end;
            });
          },
          onSelectEp: (i) => _playAt(i),
          onNext: () => _playAt(_epIdx + 1),
          onPrev: () => _playAt(_epIdx - 1),
          onDecodeChanged: (mode) {
            if (mounted) setState(() => _decodeMode = mode);
          },
          onPersistSetting: (k, v) async {
            await api.setSetting(k, v);
            if (!mounted) return;
            if (k == 'playerScale') setState(() => _aspect = _aspectFromScale(v));
            if (k == 'playerAmbient') setState(() => _ambientOn = v.toLowerCase() == 'true');
            if (k == 'playerStableVolume') {
              final on = v.toLowerCase() == 'true';
              setState(() => _stableVolumeOn = on);
              unawaited(_applyStableVolume(_playback, on));
            }
            if (k == 'danmaku') setState(() => _danmakuOn = v.toLowerCase() == 'true');
            if (k == 'danmakuApi') setState(() => _danmakuApi = v);
            if (k == 'player') {
              final prev = _playerVal;
              setState(() => _playerVal = v);
              if (v != prev && _epIdx >= 0) {
                Navigator.of(context).maybePop();
                unawaited(_playAt(_epIdx));
              }
            }
          },
          onPlayerStatus: api.playerStatus,
          onExternalPlayer: (player) => api.playerExternal(url: _playUrl, player: player),
          onToggleKeep: () async {
            final item = VodItem(id: id, name: d.name, pic: d.pic, site: site, remarks: d.remarks);
            final kept = await LocalCollect.toggle(item);
            if (mounted) setState(() => _kept = kept);
            return kept ? '取消收藏' : '收藏';
          },
          onDanmakuChanged: (v) {
            if (mounted) setState(() => _danmakuOn = v);
          },
          onAmbientChanged: (v) {
            if (mounted) setState(() => _ambientOn = v);
          },
          onParse: () {
            Navigator.of(context).maybePop();
            unawaited(_pickParse());
          },
          onRefresh: () {
            if (_epIdx >= 0) unawaited(_playAt(_epIdx));
          },
          onCast: () => unawaited(_cast()),
          onMini: () {
            Navigator.of(context).maybePop();
            unawaited(_enterMini());
          },
        ),
        ),
      ),
    );
  }

  Future<void> _cast() async {
    if (_playUrl.isEmpty) {
      if (mounted) showAppNews(context, '请先播放内容再投屏');
      return;
    }
    final msg = await runKotvCast(
      context,
      ref.read(apiProvider),
      onStatus: (m) {
        if (mounted) setState(() => _status = m);
      },
    );
    if (msg != null && mounted) setState(() => _status = msg);
  }

  Future<void> _enterMini() async {
    if (_playUrl.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('请先播放内容')));
      }
      return;
    }
    if (!MiniPlayerWindow.supported) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('当前平台不支持迷你桌面播放')));
      }
      return;
    }
    await MiniPlayerWindow.enter();
    if (!mounted) return;
    setState(() => _miniDesktop = true);
  }

  Future<void> _exitMini() async {
    await MiniPlayerWindow.exit();
    if (!mounted) return;
    setState(() => _miniDesktop = false);
  }

  Widget _videoStage({required bool interactive}) {
    final d = _detail;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        if (_playUrl.isEmpty) return;
        unawaited(_playback.playOrPause());
        setState(() {});
      },
      onDoubleTap: interactive
          ? () {
              if (_playUrl.isNotEmpty) {
                unawaited(_enterFullscreen());
              } else if (_eps.isNotEmpty) {
                unawaited(_playAt(_epIdx >= 0 ? _epIdx : 0, fullscreen: true));
              }
            }
          : null,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (_playUrl.isEmpty)
            (d == null || d.pic.isEmpty
                ? const ColoredBox(
                    color: Color(0xFF2A1848),
                    child: Center(
                      child: Text('选择剧集开始播放', style: TextStyle(color: Colors.white70, fontSize: 16)),
                    ),
                  )
                : Image.network(d.pic, fit: BoxFit.contain))
          else if (_useVlc && _vlc != null)
            EmbedVideoView(playback: _vlc!)
          else
            Video(controller: _ensureMpv().controller, controls: NoVideoControls),
          if (_status.contains('解析') || _status.contains('嗅探'))
            const ColoredBox(
              color: Color(0x66000000),
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircularProgressIndicator(color: Color(0xFFE53955), strokeWidth: 3),
                    SizedBox(height: 14),
                    Text('正在解析播放地址', style: TextStyle(color: Colors.white, fontSize: 15)),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _inlineChrome() {
    return VodInlineControls(
      player: _playback,
      miniActive: _miniDesktop,
      onCast: () => unawaited(_cast()),
      onMini: () => unawaited(_miniDesktop ? _exitMini() : _enterMini()),
      onExpand: () => unawaited(_enterFullscreen()),
      onStop: () async {
        await _stopHard();
        if (_miniDesktop) await _exitMini();
        if (mounted) {
          setState(() {
            _status = '已停止';
          });
        }
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final body = (_miniDesktop && _detail != null)
        // 主界面已收起：仅桌面悬浮播放层；控件半透明，鼠标移入显示
        ? Scaffold(
            backgroundColor: Colors.transparent,
            body: DragToMoveArea(
              child: MiniHoverShell(
                video: _videoStage(interactive: true),
                chrome: VodInlineControls(
                  player: _playback,
                  miniActive: true,
                  translucent: true,
                  onCast: () => unawaited(_cast()),
                  onMini: () => unawaited(_exitMini()),
                  onExpand: () => unawaited(_enterFullscreen()),
                  onStop: () async {
                    await _stopHard();
                    if (_miniDesktop) await _exitMini();
                    if (mounted) {
                      setState(() {
                        _status = '已停止';
                      });
                    }
                  },
                ),
              ),
            ),
          )
        : Scaffold(
            backgroundColor: Colors.transparent,
            body: AppBackdrop(
              child: Column(
                children: [
                  LibraryTopBar(
                    onBack: () => unawaited(_leavePage()),
                    onSearch: () => unawaited(_leavePage(afterPop: () => goKotvPage(ref, KotvPage.search))),
                    onProfile: () => unawaited(_leavePage(afterPop: () => goKotvPage(ref, KotvPage.profile))),
                    onNews: () => showAppNews(context, remoteHint(ref)),
                    title: widget.title.isNotEmpty ? widget.title : '详情',
                  ),
                  Expanded(
                    child: _loading
                        ? const Center(child: CircularProgressIndicator(color: Colors.white))
                        : _error != null
                            ? Center(child: Text(_error!, style: const TextStyle(color: Colors.white)))
                            : _buildBody(),
                  ),
                ],
              ),
            ),
          );

    return PopScope(
      canPop: _allowPop,
      onPopInvoked: (didPop) {
        if (didPop) return;
        unawaited(_leavePage());
      },
      child: body,
    );
  }

  Widget _buildBody() {
    final d = _detail!;
    final flags = d.flags;
    final eps = _eps;
    final pageCount = eps.isEmpty ? 0 : ((eps.length - 1) ~/ _epSize) + 1;
    final pageEps = eps.skip(_epPage * _epSize).take(_epSize).toList();
    final director = d.director.isEmpty ? '暂无' : d.director;
    final actor = d.actor.isEmpty ? '暂无' : d.actor;
    final intro = d.content.isEmpty ? '暂无' : d.content;
    final compact = KotvLayout.isCompact(context);

    Widget videoPane({required bool expand}) {
      return Container(
        decoration: BoxDecoration(
          color: const Color(0xEE0A0A12),
          borderRadius: BorderRadius.circular(14),
        ),
        padding: const EdgeInsets.all(8),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: expand
              ? Column(
                  children: [
                    Expanded(child: _videoStage(interactive: true)),
                    if (_playUrl.isNotEmpty) _inlineChrome(),
                  ],
                )
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    AspectRatio(aspectRatio: 16 / 9, child: _videoStage(interactive: true)),
                    if (_playUrl.isNotEmpty) _inlineChrome(),
                  ],
                ),
        ),
      );
    }

    Widget metaBlock({required bool scrollable}) {
      final info = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '导演：$director',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: Colors.white.withOpacity(0.78), fontSize: 15, height: 1.45),
          ),
          const SizedBox(height: 8),
          Text(
            '演员：$actor',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: Colors.white.withOpacity(0.78), fontSize: 15, height: 1.45),
          ),
          const SizedBox(height: 8),
          Text(
            '简介：$intro',
            maxLines: scrollable ? 5 : 4,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: Colors.white.withOpacity(0.72), fontSize: 15, height: 1.5),
          ),
        ],
      );
      return InkWell(
        onTap: () => _showVodMeta(d),
        borderRadius: BorderRadius.circular(8),
        child: scrollable
            ? SingleChildScrollView(child: Padding(padding: const EdgeInsets.symmetric(vertical: 2), child: info))
            : Padding(padding: const EdgeInsets.symmetric(vertical: 2), child: info),
      );
    }

    Widget actionRow() {
      return SizedBox(
        height: 58,
        child: ListView(
          scrollDirection: Axis.horizontal,
          children: [
            _action('全屏', Icons.crop_free_rounded, () {
              if (_playUrl.isNotEmpty) {
                unawaited(_enterFullscreen());
              } else if (_epIdx >= 0) {
                unawaited(_playAt(_epIdx, fullscreen: true));
              } else if (eps.isNotEmpty) {
                unawaited(_playAt(0, fullscreen: true));
              }
            }),
            _action('搜索', Icons.search_rounded, () {
              final q = _quickSearchQuery(d);
              unawaited(_leavePage(afterPop: () {
                ref.read(pendingSearchProvider.notifier).state = q;
                goKotvPage(ref, KotvPage.search);
              }));
            }),
            _action(_reversed ? '正序' : '倒叙', Icons.swap_vert_rounded, () => setState(() {
                  _reversed = !_reversed;
                  _epPage = 0;
                  _epIdx = -1;
                  _status = _reversed ? '已倒序' : '已正序';
                })),
            _action(_kept ? '取消收藏' : '收藏', Icons.star_border_rounded, () async {
              final kept = await LocalCollect.toggle(VodItem(
                id: d.id.isNotEmpty ? d.id : widget.id,
                name: d.name,
                pic: d.pic,
                site: d.site.isNotEmpty ? d.site : widget.site,
                remarks: d.remarks,
              ));
              setState(() {
                _kept = kept;
                _status = kept ? '已加入收藏' : '已取消收藏';
              });
            }),
            _action('换源', Icons.visibility_outlined, () {
              if (flags.length <= 1) {
                setState(() => _status = '仅一条线路，无法换源');
                return;
              }
              final next = (_flagIdx + 1) % flags.length;
              setState(() {
                _flagIdx = next;
                _epPage = 0;
                _epIdx = -1;
                _status = '已自动切换线路: ${flags[next].show}';
              });
              final nextEps = _eps;
              if (nextEps.isNotEmpty) {
                _playAt(0);
              }
            }),
            _action('解析', Icons.tune_rounded, () => _pickParse()),
          ],
        ),
      );
    }

    Widget lower() {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 22),
          Row(
            children: [
              const Text('视频来源', style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w700)),
              const SizedBox(width: 14),
              Expanded(
                child: SizedBox(
                  height: 38,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: flags.length,
                    separatorBuilder: (_, __) => const SizedBox(width: 8),
                    itemBuilder: (_, i) => AppPill(
                      label: flags[i].show,
                      height: 36,
                      selected: i == _flagIdx,
                      onTap: () => setState(() {
                        _flagIdx = i;
                        _epPage = 0;
                        _epIdx = -1;
                      }),
                    ),
                  ),
                ),
              ),
            ],
          ),
          if (pageCount > 1) ...[
            const SizedBox(height: 12),
            SizedBox(
              height: 36,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: pageCount,
                separatorBuilder: (_, __) => const SizedBox(width: 8),
                itemBuilder: (_, i) {
                  final from = i * _epSize + 1;
                  final to = ((i + 1) * _epSize).clamp(0, eps.length);
                  return AppPill(
                    label: '$from-$to',
                    height: 36,
                    selected: i == _epPage,
                    onTap: () => setState(() => _epPage = i),
                  );
                },
              ),
            ),
          ],
          const SizedBox(height: 14),
          if (pageEps.isEmpty)
            const Text('无剧集', style: TextStyle(color: Colors.white70))
          else
            LayoutBuilder(
              builder: (context, c) {
                final cols = compact ? 3 : 6;
                const gap = 10.0;
                final w = (c.maxWidth - gap * (cols - 1)) / cols;
                return Wrap(
                  spacing: gap,
                  runSpacing: gap,
                  children: [
                    for (var i = 0; i < pageEps.length; i++)
                      SizedBox(
                        width: w,
                        height: 42,
                        child: EpisodeChip(
                          label: pageEps[i].name,
                          selected: _epIdx == _epPage * _epSize + i,
                          autofocus: i == 0,
                          onTap: () => _playAt(_epPage * _epSize + i),
                        ),
                      ),
                  ],
                );
              },
            ),
        ],
      );
    }

    if (compact) {
      return ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 36),
        children: [
          videoPane(expand: false),
          const SizedBox(height: 14),
          Text(
            d.name,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.w700, height: 1.25),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 16,
            runSpacing: 6,
            children: [
              _meta('更新：${d.remarks.isEmpty ? '暂无' : d.remarks}'),
              _meta('来源：${d.site.isEmpty ? '未知' : d.site}'),
              _meta('年份：${d.year.isEmpty ? '暂无' : d.year}'),
              if (d.area.isNotEmpty) _meta('地区：${d.area}'),
            ],
          ),
          const SizedBox(height: 10),
          metaBlock(scrollable: false),
          const SizedBox(height: 6),
          Text(_status, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: Colors.white.withOpacity(0.55), fontSize: 12)),
          const SizedBox(height: 8),
          actionRow(),
          lower(),
        ],
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final upperH = (constraints.maxHeight * 0.52).clamp(360.0, 520.0);
        return ListView(
          padding: const EdgeInsets.fromLTRB(48, 8, 48, 36),
          children: [
            SizedBox(
              height: upperH,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(flex: 42, child: videoPane(expand: true)),
                  const SizedBox(width: 36),
                  Expanded(
                    flex: 58,
                    child: Padding(
                      padding: const EdgeInsets.only(top: 4, bottom: 2),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            d.name,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 28,
                              fontWeight: FontWeight.w700,
                              height: 1.25,
                              letterSpacing: 0.3,
                            ),
                          ),
                          const SizedBox(height: 12),
                          Wrap(
                            spacing: 28,
                            runSpacing: 6,
                            children: [
                              _meta('更新：${d.remarks.isEmpty ? '暂无' : d.remarks}'),
                              _meta('来源：${d.site.isEmpty ? '未知' : d.site}'),
                              _meta('年份：${d.year.isEmpty ? '暂无' : d.year}'),
                              if (d.area.isNotEmpty) _meta('地区：${d.area}'),
                            ],
                          ),
                          const SizedBox(height: 12),
                          Expanded(child: metaBlock(scrollable: true)),
                          const SizedBox(height: 6),
                          Text(
                            _status,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(color: Colors.white.withOpacity(0.55), fontSize: 12),
                          ),
                          const SizedBox(height: 8),
                          actionRow(),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
            lower(),
          ],
        );
      },
    );
  }

  Future<void> _pickParse() async {
    try {
      final st = await ref.read(apiProvider).getSettings();
      final parses = ((st['parses'] as List?) ?? []).whereType<Map>().toList();
      if (parses.isEmpty) {
        setState(() => _status = '当前配置无解析器');
        return;
      }
      final names = parses.map((e) => '${e['name'] ?? ''}').where((e) => e.isNotEmpty).toList();
      final cur = '${(st['settings'] as Map?)?['preferredParse'] ?? ''}';
      final picked = await showDialog<String>(
        context: context,
        builder: (ctx) => SimpleDialog(
          backgroundColor: const Color(0xFF1C1C22),
          title: const Text('选择解析器', style: TextStyle(color: Colors.white)),
          children: [
            SimpleDialogOption(
              onPressed: () => Navigator.pop(ctx, ''),
              child: Text('自动（默认）${cur.isEmpty ? '  ✓' : ''}', style: const TextStyle(color: Colors.white)),
            ),
            for (final n in names)
              SimpleDialogOption(
                onPressed: () => Navigator.pop(ctx, n),
                child: Text('$n${cur == n ? '  ✓' : ''}', style: const TextStyle(color: Colors.white)),
              ),
          ],
        ),
      );
      if (picked == null) return;
      await ref.read(apiProvider).setSetting('preferredParse', picked);
      setState(() => _status = picked.isEmpty ? '解析器: 自动' : '解析器: $picked');
      if (_epIdx >= 0) _playAt(_epIdx);
    } catch (e) {
      setState(() => _status = '$e');
    }
  }

  Widget _meta(String t) => Text(
        t,
        style: TextStyle(color: Colors.white.withOpacity(0.72), fontSize: 14.5, height: 1.3),
      );

  String _quickSearchQuery(VodDetail d) {
    var q = d.actor.trim();
    if (q.isEmpty || q == '暂无') return d.name;
    for (final sep in [',', '，', '/', '、', ' ']) {
      final i = q.indexOf(sep);
      if (i > 0) {
        q = q.substring(0, i).trim();
        break;
      }
    }
    return q.isEmpty ? d.name : q;
  }

  void _showVodMeta(VodDetail d) {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1C1C22),
        title: Text(d.name, style: const TextStyle(color: Colors.white)),
        content: SizedBox(
          width: 520,
          child: SingleChildScrollView(
            child: Text(
              '导演：${d.director.isEmpty ? '暂无' : d.director}\n'
              '演员：${d.actor.isEmpty ? '暂无' : d.actor}\n'
              '类型：${d.typeName.isEmpty ? '暂无' : d.typeName}\n'
              '年份：${d.year.isEmpty ? '暂无' : d.year}\n'
              '地区：${d.area.isEmpty ? '暂无' : d.area}\n'
              '备注：${d.remarks.isEmpty ? '暂无' : d.remarks}\n\n'
              '${d.content.isEmpty ? '暂无简介' : d.content}',
              style: const TextStyle(color: Colors.white70, height: 1.55, fontSize: 15),
            ),
          ),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('关闭'))],
      ),
    );
  }

  Widget _action(String label, IconData icon, VoidCallback onTap) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: TvFocus(
        onPressed: onTap,
        borderRadius: 10,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(10),
            child: Ink(
              width: 72,
              height: 56,
              decoration: BoxDecoration(
                color: const Color(0x66101018),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.white.withOpacity(0.08)),
              ),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(icon, color: Colors.white, size: 20),
                  const SizedBox(height: 4),
                  Text(
                    label,
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: Colors.white.withOpacity(0.8), fontSize: 11, height: 1.1),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
