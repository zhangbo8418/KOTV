import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';

import '../desktop/mini_player_window.dart';
import '../player/embed_video_view.dart';
import '../player/kotv_platform.dart';
import '../player/kotv_playback.dart';
import '../providers.dart';
import '../remote/remote_bridge.dart';
import '../theme/kotv_palette.dart';
import '../theme/layout_scale.dart';
import '../widgets/cast_flow.dart';
import '../widgets/chrome.dart';
import '../widgets/dialogs.dart';
import '../widgets/live_player_chrome.dart';
import '../widgets/mini_hover_shell.dart';
import 'shell.dart';

const _liveKeepSep = '\$\$\$';
const _liveKeepPrefKey = 'kotv_live_keep';

class LiveScreen extends ConsumerStatefulWidget {
  const LiveScreen({super.key});

  @override
  ConsumerState<LiveScreen> createState() => _LiveScreenState();
}

class _LiveScreenState extends ConsumerState<LiveScreen> {
  Player? _mkPlayer;
  MediaKitPlayback? _mk;
  EngineVlcPlayback? _vlc;
  final FocusNode _focus = FocusNode();

  KotvPlayback get _playback {
    if (_useVlc) {
      return _vlc ??= EngineVlcPlayback();
    }
    return _ensureMpv();
  }

  bool get _useVlc => _playerVal.trim() == 'innie#vlc';

  MediaKitPlayback _ensureMpv() {
    _mkPlayer ??= Player();
    _mk ??= MediaKitPlayback(_mkPlayer!);
    return _mk!;
  }

  VideoController get _controller => _ensureMpv().controller;

  bool _loading = true;
  String? _error;
  List<Map<String, dynamic>> _sources = [];
  List<Map<String, dynamic>> _groups = [];
  final Set<int> _unlocked = {};
  List<Map<String, dynamic>> _epgDays = [];
  List<Map<String, dynamic>> _programs = [];
  int _srcIdx = 0;
  int _groupIdx = 0;
  int _chIdx = -1;
  int _dayIdx = 0;
  int _line = 0;
  int _lines = 1;
  bool _leftOpen = true;
  bool _rightOpen = false;
  bool _catchup = false;
  bool _catchupChrome = false;
  bool _miniDesktop = false;
  /// 竖屏面板：0=频道 1=EPG
  int _portraitTab = 0;
  /// 竖屏播放器底栏显隐（点画面切换）
  bool _portraitChrome = true;
  String _status = '点击左侧换台 · 点击右侧换源/设置';
  String _title = '选择频道开始播放';
  String _decodeMode = 'auto';
  String _playerVal = kotvDefaultLivePlayer();
  String _playUrl = '';
  Timer? _catchupHideTimer;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  @override
  void dispose() {
    if (_miniDesktop) {
      unawaited(MiniPlayerWindow.exit());
    }
    _hideTimer?.cancel();
    _catchupHideTimer?.cancel();
    _focus.dispose();
    unawaited(_vlc?.stop() ?? Future<void>.value());
    unawaited(_mk?.stop() ?? Future<void>.value());
    _vlc?.dispose();
    _mk?.dispose();
    _mkPlayer?.dispose();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    setState(() {
      _loading = true;
      _error = null;
      _unlocked.clear();
    });
    try {
      try {
        final st = await ref.read(apiProvider).getSettings();
        final settings = Map<String, dynamic>.from((st['settings'] as Map?) ?? const {});
        final decode = '${settings['playerDecode'] ?? 'auto'}'.trim();
        if (decode.isNotEmpty) _decodeMode = decode;
        var playerVal = '${settings['playerLive'] ?? ''}'.trim();
        if (playerVal.isEmpty) {
          playerVal = kotvDefaultLivePlayer();
        }
        _playerVal = playerVal;
        // Win7：进页不碰 native 播放器；等用户点台再 open。
        if (!kotvIsWindows7()) {
          final vol = double.tryParse('${settings['playerVolume'] ?? ''}');
          if (vol != null) {
            await _playback.setVolume(vol.clamp(0, 100));
          }
          await _playback.setDecodeMode(_decodeMode);
        }
      } catch (_) {}
      final data = await ref.read(apiProvider).liveSources();
      _sources = ((data['sources'] as List?) ?? []).whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
      if (_sources.isEmpty) {
        setState(() => _loading = false);
        return;
      }
      final keepSrc = await _preferredSourceIndex();
      // Win7：进页自动开播易卡死 UI，等用户点台。
      await _loadSource(keepSrc, autoPlay: !kotvIsWindows7());
      if (kotvIsWindows7() && mounted) {
        setState(() => _status = '点击左侧频道开始播放（Win7 已禁用进页自动播）');
      }
    } catch (e) {
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  Future<String> _readLiveKeep() async {
    try {
      final st = await ref.read(apiProvider).getSettings();
      final keep = '${((st['settings'] as Map?) ?? const {})['liveKeep'] ?? ''}'.trim();
      if (keep.isNotEmpty) return keep;
    } catch (_) {}
    try {
      final prefs = await SharedPreferences.getInstance();
      return (prefs.getString(_liveKeepPrefKey) ?? '').trim();
    } catch (_) {
      return '';
    }
  }

  Future<int> _preferredSourceIndex() async {
    try {
      final keep = await _readLiveKeep();
      if (keep.isEmpty || _sources.isEmpty) return 0;
      final parts = keep.split(_liveKeepSep);
      if (parts.isEmpty) return 0;
      final srcName = parts[0];
      for (var i = 0; i < _sources.length; i++) {
        final n = '${_sources[i]['name'] ?? ''}';
        final u = '${_sources[i]['url'] ?? ''}';
        if (n == srcName) return i;
        if (srcName.isNotEmpty && (n.contains(srcName) || srcName.contains(n) || u.contains(srcName))) return i;
      }
    } catch (_) {}
    return 0;
  }

  Future<void> _loadSource(int index, {bool autoPlay = false}) async {
    setState(() {
      _loading = true;
      _srcIdx = index;
      _status = '加载直播源…';
      _unlocked.clear();
      _epgDays = [];
      _programs = [];
      _catchup = false;
      _catchupChrome = false;
    });
    try {
      final data = await ref.read(apiProvider).liveLoad(index: index);
      _groups = ((data['groups'] as List?) ?? []).whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
      _groupIdx = 0;
      _chIdx = -1;
      setState(() {
        _loading = false;
        _title = '${data['name'] ?? '直播'}';
        _status = '点击左侧换台 · 点击右侧换源/设置';
      });
      if (autoPlay) {
        final restored = await _tryRestoreKeep();
        if (!restored) await _playFirstChannel();
      }
    } catch (e) {
      setState(() {
        _loading = false;
        _status = '加载失败: $e';
      });
    }
  }

  Future<bool> _tryRestoreKeep() async {
    try {
      final keep = await _readLiveKeep();
      if (keep.isEmpty) return false;
      final parts = keep.split(_liveKeepSep);
      if (parts.length < 3) return false;
      final groupName = parts[1];
      final chName = parts[2];
      final lineURL = parts.length >= 4 ? parts[3] : '';
      for (var gi = 0; gi < _groups.length; gi++) {
        if (_groupLocked(gi)) continue;
        final gName = '${_groups[gi]['name'] ?? ''}';
        if (groupName.isNotEmpty && gName != groupName) continue;
        final chs = ((_groups[gi]['channels'] as List?) ?? []).whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
        for (var ci = 0; ci < chs.length; ci++) {
          if ('${chs[ci]['name'] ?? ''}' != chName) continue;
          var line = (chs[ci]['line'] as int?) ?? 0;
          if (lineURL.isNotEmpty) {
            final asIdx = int.tryParse(lineURL);
            if (asIdx != null && asIdx >= 0) {
              line = asIdx;
            }
          }
          setState(() {
            _groupIdx = gi;
            _chIdx = ci;
          });
          await _playChannel(ci, line: line);
          return true;
        }
      }
    } catch (_) {}
    return false;
  }

  Future<void> _playFirstChannel() async {
    var start = 0;
    if (_groups.length > 1 && '${_groups[0]['name'] ?? ''}' == '收藏') start = 1;
    for (var n = 0; n < _groups.length; n++) {
      final gi = (start + n) % _groups.length;
      if (_groupLocked(gi)) continue;
      final chs = ((_groups[gi]['channels'] as List?) ?? []).whereType<Map>().toList();
      if (chs.isEmpty) continue;
      setState(() => _groupIdx = gi);
      await _playChannel(0);
      return;
    }
  }

  Future<void> _saveLiveKeep() async {
    if (_chIdx < 0 || _groups.isEmpty) return;
    final g = _groups[_groupIdx.clamp(0, _groups.length - 1)];
    final chs = _channels;
    if (_chIdx >= chs.length) return;
    final ch = chs[_chIdx];
    final srcName = '${_sources.isEmpty ? '' : (_sources[_srcIdx]['name'] ?? _sources[_srcIdx]['url'] ?? '')}';
    final groupName = '${g['name'] ?? '未分组'}';
    final chName = '${ch['name'] ?? ''}';
    // 线路记序号，避免代理 URL 变化导致无法匹配
    final lineURL = '$_line';
    final val = [srcName, groupName, chName, lineURL].join(_liveKeepSep);
    try {
      await ref.read(apiProvider).setSetting('liveKeep', val);
    } catch (_) {}
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_liveKeepPrefKey, val);
    } catch (_) {}
  }

  List<Map<String, dynamic>> get _channels {
    if (_groups.isEmpty) return const [];
    final g = _groups[_groupIdx.clamp(0, _groups.length - 1)];
    return ((g['channels'] as List?) ?? []).whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
  }

  bool _groupLocked(int i) {
    if (i < 0 || i >= _groups.length) return false;
    final locked = _groups[i]['locked'] == true;
    return locked && !_unlocked.contains(i);
  }

  Future<bool> _ensureUnlocked(int groupIdx) async {
    if (!_groupLocked(groupIdx)) return true;
    final ctrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF63248A),
        title: const Text('解锁分组', style: TextStyle(color: Colors.white)),
        content: TextField(
          controller: ctrl,
          obscureText: true,
          style: const TextStyle(color: Colors.white),
          decoration: const InputDecoration(
            hintText: '请输入分组密码',
            hintStyle: TextStyle(color: Colors.white38),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('确定')),
        ],
      ),
    );
    if (ok != true) {
      ctrl.dispose();
      return false;
    }
    try {
      await ref.read(apiProvider).liveUnlock(group: groupIdx, password: ctrl.text.trim());
      setState(() => _unlocked.add(groupIdx));
      ctrl.dispose();
      return true;
    } catch (e) {
      ctrl.dispose();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      }
      return false;
    }
  }

  Future<void> _selectGroup(int i) async {
    if (!await _ensureUnlocked(i)) return;
    setState(() {
      _groupIdx = i;
      _chIdx = -1;
      _epgDays = [];
      _programs = [];
    });
  }

  Future<void> _loadEpg() async {
    if (_chIdx < 0) return;
    try {
      final data = await ref.read(apiProvider).liveEpg(group: _groupIdx, channel: _chIdx);
      final days = ((data['days'] as List?) ?? []).whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
      var dayIdx = 0;
      final today = DateTime.now().toIso8601String().substring(0, 10);
      for (var i = 0; i < days.length; i++) {
        if ('${days[i]['date']}' == today) {
          dayIdx = i;
          break;
        }
      }
      final progs = days.isEmpty
          ? <Map<String, dynamic>>[]
          : (((days[dayIdx]['list'] as List?) ?? []).whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList());
      if (!mounted) return;
      setState(() {
        _epgDays = days;
        _dayIdx = dayIdx;
        _programs = progs;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _epgDays = [];
          _programs = [];
        });
      }
    }
  }

  Future<void> _openLiveUrl(String url) async {
    await _playback.setDecodeMode(_decodeMode);
    if (_useVlc) {
      try {
        await _mk?.stop();
      } catch (_) {}
      _vlc ??= EngineVlcPlayback();
      await _vlc!.setDecodeMode(_decodeMode);
      // 原生 create/load/play 偶发阻塞；超时后提示用户改外部播放器。
      try {
        await _vlc!.open(url).timeout(const Duration(seconds: 12));
      } on TimeoutException {
        if (mounted) {
          setState(() => _status = '内置 VLC 开播超时，可改用外部播放器');
        }
        rethrow;
      }
    } else {
      try {
        await _vlc?.stop();
      } catch (_) {}
      // Win7 上 media_kit 偶发同步卡死：开播加超时，失败则自动切 VLC。
      final mk = _ensureMpv();
      try {
        await mk.open(url).timeout(const Duration(seconds: 8));
      } on TimeoutException {
        _playerVal = 'innie#vlc';
        try {
          await ref.read(apiProvider).setSetting('playerLive', 'innie#vlc');
        } catch (_) {}
        try {
          await mk.stop();
        } catch (_) {}
        _vlc ??= EngineVlcPlayback();
        await _vlc!.setDecodeMode(_decodeMode);
        await _vlc!.open(url);
        if (mounted) {
          setState(() => _status = 'MPV 超时，已自动切到内置 VLC');
        }
      }
    }
    _playUrl = url;
  }

  Widget _liveVideo() {
    if (_playUrl.isEmpty) {
      return const ColoredBox(color: Colors.black);
    }
    if (_useVlc) {
      final vlc = _vlc ??= EngineVlcPlayback();
      return EmbedVideoView(playback: vlc);
    }
    return Video(controller: _controller, controls: NoVideoControls);
  }

  Future<void> _playChannel(int chIdx, {int? line}) async {
    if (!await _ensureUnlocked(_groupIdx)) return;
    final chs = _channels;
    if (chIdx < 0 || chIdx >= chs.length) return;
    final ch = chs[chIdx];
    final useLine = line ?? (ch['line'] as int? ?? 0);
    setState(() {
      _chIdx = chIdx;
      _line = useLine;
      _status = '解析中…';
      _title = '${ch['name'] ?? ''}';
      _leftOpen = true;
      _catchup = false;
      _catchupChrome = false;
    });
    try {
      final data = await ref.read(apiProvider).livePlay(group: _groupIdx, channel: chIdx, line: useLine);
      final url = '${data['url'] ?? ''}';
      if (url.isEmpty) throw Exception('空播放地址');
      _lines = (data['lines'] as int?) ?? 1;
      _line = (data['line'] as int?) ?? useLine;
      await _openLiveUrl(url);
      setState(() => _status = '播放中 · $_title');
      _scheduleHideOverlays();
      unawaited(_loadEpg());
      await _saveLiveKeep();
      ref.read(remoteBridgeProvider)?.reportMedia(state: 'playing', title: _title, url: url);
    } catch (e) {
      setState(() => _status = '播放失败: $e');
    }
  }

  Future<void> _playCatchup(int progIdx) async {
    try {
      setState(() => _status = '加载回看…');
      final data = await ref.read(apiProvider).liveCatchup(
            group: _groupIdx,
            channel: _chIdx,
            day: _dayIdx,
            prog: progIdx,
          );
      final url = '${data['url'] ?? ''}';
      if (url.isEmpty) throw Exception('空回看地址');
      await _openLiveUrl(url);
      setState(() {
        _title = '${data['name'] ?? _title}';
        _status = '回看中 · $_title';
        _catchup = true;
        _catchupChrome = true;
        _leftOpen = false;
        _rightOpen = false;
      });
      _pulseCatchupChrome();
      ref.read(remoteBridgeProvider)?.reportMedia(state: 'playing', title: _title, url: url);
    } catch (e) {
      setState(() => _status = '回看失败: $e');
    }
  }

  void _pulseCatchupChrome() {
    _catchupHideTimer?.cancel();
    setState(() => _catchupChrome = true);
    _catchupHideTimer = Timer(const Duration(seconds: 5), () {
      if (mounted && _catchup && !_miniDesktop) {
        setState(() => _catchupChrome = false);
      }
    });
  }

  void _toggleCatchupChrome() {
    if (!_catchup) return;
    if (_catchupChrome) {
      _catchupHideTimer?.cancel();
      setState(() => _catchupChrome = false);
    } else {
      _pulseCatchupChrome();
    }
  }

  Future<void> _cast() async {
    if (_playUrl.isEmpty) {
      if (mounted) showAppNews(context, '请先播放内容再投屏');
      return;
    }
    final msg = await runKotvCast(context, ref.read(apiProvider), onStatus: (m) {
      if (mounted) setState(() => _status = m);
    });
    if (msg != null && mounted) setState(() => _status = msg);
  }

  Future<void> _enterMini() async {
    if (_playUrl.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('请先播放内容')));
      }
      return;
    }
    if (!MiniPlayerWindow.supported) return;
    await MiniPlayerWindow.enter();
    if (!mounted) return;
    setState(() {
      _miniDesktop = true;
      _leftOpen = false;
      _rightOpen = false;
      if (_catchup) _catchupChrome = true;
    });
  }

  Future<void> _exitMini() async {
    await MiniPlayerWindow.exit();
    if (!mounted) return;
    setState(() => _miniDesktop = false);
  }

  Future<void> _enterLiveFullscreen() async {
    if (_playUrl.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('请先选择频道播放')));
      }
      return;
    }
    if (_miniDesktop) await _exitMini();
    if (kotvIsDesktop()) {
      try {
        await windowManager.setFullScreen(true);
      } catch (_) {}
    }
    try {
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    } catch (_) {}
    if (!mounted) return;
    await Navigator.of(context, rootNavigator: true).push(
      PageRouteBuilder(
        opaque: true,
        pageBuilder: (ctx, _, __) => Scaffold(
          backgroundColor: Colors.black,
          body: SafeArea(
            child: Stack(
              fit: StackFit.expand,
              children: [
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () {},
                  child: _liveVideo(),
                ),
                Positioned(
                  top: 8,
                  left: 8,
                  child: AppPill(
                    label: '退出全屏',
                    height: 32,
                    fontSize: 12,
                    onTap: () => Navigator.of(ctx).pop(),
                  ),
                ),
                Positioned(
                  top: 8,
                  right: 8,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      AppPill(
                        label: '上一台',
                        height: 32,
                        fontSize: 12,
                        onTap: () {
                          final chs = _channels;
                          if (chs.isEmpty) return;
                          _playChannel(_chIdx <= 0 ? chs.length - 1 : _chIdx - 1);
                        },
                      ),
                      const SizedBox(width: 6),
                      AppPill(
                        label: '下一台',
                        height: 32,
                        fontSize: 12,
                        onTap: () {
                          final chs = _channels;
                          if (chs.isEmpty) return;
                          _playChannel((_chIdx + 1) % chs.length);
                        },
                      ),
                    ],
                  ),
                ),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: LiveCatchupChrome(
                    player: _playback,
                    playerLabel: flutterPlayerLabel(_playerVal),
                    decodeLabel: _decodeLabel,
                    onCast: () => unawaited(_cast()),
                    onPlayer: () => unawaited(_pickPlayer()),
                    onDecode: () => unawaited(_pickDecode()),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    try {
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    } catch (_) {}
    if (kotvIsDesktop()) {
      try {
        await windowManager.setFullScreen(false);
      } catch (_) {}
    }
  }

  Future<void> _pickDecode() async {
    final v = await pickChoice(context, title: '解码方式', current: _decodeMode, options: const [
      ('自动', 'auto'),
      ('软解码', 'soft'),
      ('硬解码', 'hard'),
    ]);
    if (v == null) return;
    setState(() => _decodeMode = v);
    await _playback.setDecodeMode(v);
    try {
      await ref.read(apiProvider).setSetting('playerDecode', v);
    } catch (_) {}
    if (_playUrl.isNotEmpty) {
      final pos = _playback.position;
      await _openLiveUrl(_playUrl);
      if (pos > Duration.zero) await _playback.seek(pos);
    }
  }

  Future<void> _pickPlayer() async {
    final options = <(String, String)>[
      ('内置 MPV', 'innie#mpv'),
      ('内置 VLC', 'innie#vlc'),
      ('外部 VLC', 'outie#vlc'),
      ('外部 MPV', 'outie#mpv'),
      ('外部 IINA', 'outie#iina'),
    ];
    final v = await pickChoice(context, title: '直播播放器', current: _playerVal, options: options);
    if (v == null) return;
    final prev = _playerVal;
    setState(() => _playerVal = v);
    try {
      await ref.read(apiProvider).setSetting('playerLive', v);
    } catch (_) {}
    if (v.startsWith('outie#') && _playUrl.isNotEmpty) {
      try {
        await ref.read(apiProvider).playerExternal(url: _playUrl, player: v);
        await _playback.pause();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('已用${flutterPlayerLabel(v)}打开')));
        }
      } catch (e) {
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      }
      return;
    }
    if (v != prev && _playUrl.isNotEmpty && (v == 'innie#mpv' || v == 'innie#vlc')) {
      final pos = _playback.position;
      await _openLiveUrl(_playUrl);
      if (pos > Duration.zero) await _playback.seek(pos);
      if (mounted) setState(() {});
    }
  }

  String get _decodeLabel {
    switch (_decodeMode) {
      case 'soft':
        return '软解码';
      case 'hard':
        return '硬解码';
      default:
        return '自动';
    }
  }

  Timer? _hideTimer;
  int _edgeZone = -1;

  void _cancelHideOverlays() {
    _hideTimer?.cancel();
    _hideTimer = null;
  }

  void _scheduleHideOverlays() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 8), () {
      if (mounted) {
        setState(() {
          _leftOpen = false;
          _rightOpen = false;
        });
      }
    });
  }

  void _openLeft() => setState(() {
        _leftOpen = true;
        _rightOpen = false;
        _cancelHideOverlays();
      });

  void _openRight() => setState(() {
        _rightOpen = true;
        _leftOpen = false;
        _cancelHideOverlays();
      });

  void _toggleLeft() => setState(() {
        _leftOpen = !_leftOpen;
        if (_leftOpen) {
          _rightOpen = false;
          _cancelHideOverlays();
        } else {
          _scheduleHideOverlays();
        }
      });

  void _toggleRight() => setState(() {
        _rightOpen = !_rightOpen;
        if (_rightOpen) {
          _leftOpen = false;
          _cancelHideOverlays();
        } else {
          _scheduleHideOverlays();
        }
      });

  void _onHover(PointerHoverEvent e, BoxConstraints c) {
    const hot = 16.0;
    var zone = -1;
    if (e.localPosition.dx <= hot) {
      zone = 0;
    } else if (e.localPosition.dx >= c.maxWidth - hot) {
      zone = 2;
    }
    if (zone == _edgeZone) return;
    _edgeZone = zone;
    if (zone == 0) {
      _openLeft();
    } else if (zone == 2) {
      _openRight();
    }
  }

  String get _currentLogo {
    final chs = _channels;
    if (_chIdx < 0 || _chIdx >= chs.length) return '';
    return '${chs[_chIdx]['logo'] ?? ''}';
  }

  String get _programLabel {
    for (final p in _programs) {
      if (p['now'] == true) return '${p['label'] ?? p['title'] ?? ''}';
    }
    if (_programs.isNotEmpty) return '${_programs.first['label'] ?? _programs.first['title'] ?? ''}';
    return '';
  }

  String get _channelNum => _chIdx < 0 ? '--' : '${_chIdx + 1}'.padLeft(2, '0');

  String get _lineLabel => _chIdx < 0 || _lines <= 1 ? '' : '线路 ${_line + 1}/$_lines';

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final chs = _channels;
    switch (event.logicalKey) {
      case LogicalKeyboardKey.escape:
        goKotvPage(ref, KotvPage.video);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.keyM:
        _toggleRight();
        return KeyEventResult.handled;
      case LogicalKeyboardKey.enter:
      case LogicalKeyboardKey.space:
        _toggleLeft();
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowUp:
        if (chs.isEmpty) return KeyEventResult.handled;
        final next = _chIdx <= 0 ? chs.length - 1 : _chIdx - 1;
        _playChannel(next);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowDown:
        if (chs.isEmpty) return KeyEventResult.handled;
        _playChannel((_chIdx + 1) % chs.length);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowLeft:
        if (_catchup) {
          final next = _playback.position - const Duration(seconds: 15);
          unawaited(_playback.seek(next < Duration.zero ? Duration.zero : next));
          _pulseCatchupChrome();
        } else if (_chIdx >= 0 && _lines > 1) {
          _playChannel(_chIdx, line: (_line - 1 + _lines) % _lines);
        }
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowRight:
        if (_catchup) {
          unawaited(_playback.seek(_playback.position + const Duration(seconds: 15)));
          _pulseCatchupChrome();
        } else if (_chIdx >= 0 && _lines > 1) {
          _playChannel(_chIdx, line: (_line + 1) % _lines);
        }
        return KeyEventResult.handled;
      default:
        return KeyEventResult.ignored;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (!_loading && _sources.isEmpty && _error == null) {
      return Column(
        children: [
          LibraryTopBar(
            onBack: () => goKotvPage(ref, KotvPage.video),
            onSearch: () => goKotvPage(ref, KotvPage.search),
            onProfile: () => goKotvPage(ref, KotvPage.profile),
            onNews: () => showAppNews(context, remoteHint(ref)),
            title: '直播',
          ),
          Expanded(
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('请先在设置中配置直播源，或在点播配置中包含 lives', style: TextStyle(color: Colors.white70, fontSize: 16)),
                  const SizedBox(height: 16),
                  AppPill(label: '打开设置', width: 140, selected: true, onTap: () => goKotvPage(ref, KotvPage.settings)),
                  const SizedBox(height: 10),
                  AppPill(
                    label: '配置直播源',
                    width: 140,
                    onTap: () async {
                      await showAddLiveDialog(context, ref);
                      await _bootstrap();
                    },
                  ),
                ],
              ),
            ),
          ),
        ],
      );
    }

    if (_miniDesktop) {
      return Scaffold(
        backgroundColor: Colors.transparent,
        body: DragToMoveArea(
          child: MiniHoverShell(
            video: _liveVideo(),
            chrome: LiveCatchupChrome(
              player: _playback,
              miniActive: true,
              translucent: true,
              playerLabel: flutterPlayerLabel(_playerVal),
              decodeLabel: _decodeLabel,
              onCast: () => unawaited(_cast()),
              onMini: () => unawaited(_exitMini()),
              onPlayer: () => unawaited(_pickPlayer()),
              onDecode: () => unawaited(_pickDecode()),
            ),
          ),
        ),
      );
    }

    // 竖屏 / 窄窗：上播放器 + 下频道列表（移动端布局）
    if (KotvLayout.useBottomNav(context) || KotvLayout.isCompact(context)) {
      return _buildPortraitLive();
    }

    return Focus(
      focusNode: _focus,
      autofocus: true,
      onKeyEvent: _onKey,
      child: ColoredBox(
        color: Colors.black,
        child: LayoutBuilder(
          builder: (context, c) {
            return MouseRegion(
              onHover: (e) => _onHover(e, c),
              onExit: (_) => _edgeZone = -1,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  _liveVideo(),
                  if (_loading) const Center(child: CircularProgressIndicator(color: Colors.white)),
                  if (_error != null) Center(child: Text(_error!, style: const TextStyle(color: Colors.white70))),
                  // 点击分区：左 28% 频道 / 右 28% 设置 / 中 显隐
                  Positioned.fill(
                    child: Row(
                      children: [
                        Expanded(
                          flex: 28,
                          child: GestureDetector(behavior: HitTestBehavior.translucent, onTap: _toggleLeft),
                        ),
                        Expanded(
                          flex: 44,
                          child: GestureDetector(
                            behavior: HitTestBehavior.translucent,
                            onTap: () {
                              if (_leftOpen || _rightOpen) {
                                setState(() {
                                  _leftOpen = false;
                                  _rightOpen = false;
                                });
                              } else if (_catchup) {
                                _toggleCatchupChrome();
                              } else {
                                _openLeft();
                                _scheduleHideOverlays();
                              }
                            },
                          ),
                        ),
                        Expanded(
                          flex: 28,
                          child: GestureDetector(behavior: HitTestBehavior.translucent, onTap: _toggleRight),
                        ),
                      ],
                    ),
                  ),
                  if (_leftOpen || _rightOpen)
                    Positioned(
                      left: 16,
                      top: 12,
                      child: AppPill(label: '返回', width: 96, height: 36, onTap: () => goKotvPage(ref, KotvPage.video)),
                    ),
                  if (_leftOpen)
                    Positioned(
                      left: 0,
                      top: 56,
                      bottom: 72,
                      child: MouseRegion(
                        onEnter: (_) => _cancelHideOverlays(),
                        onExit: (_) => _scheduleHideOverlays(),
                        child: Material(
                          color: const Color(0x99120A24),
                          child: SizedBox(
                            width: 640,
                            child: Padding(
                              padding: const EdgeInsets.all(8),
                              child: Row(
                                children: [
                                  SizedBox(
                                    width: 148,
                                    child: ListView.builder(
                                      itemCount: _groups.length,
                                      itemBuilder: (_, i) {
                                        final g = _groups[i];
                                        final locked = _groupLocked(i);
                                        return Padding(
                                          padding: const EdgeInsets.only(bottom: 6),
                                          child: AppPill(
                                            label: '${locked ? '🔒 ' : ''}${g['name'] ?? ''}',
                                            height: 36,
                                            fontSize: 13,
                                            selected: i == _groupIdx,
                                            onTap: () => _selectGroup(i),
                                          ),
                                        );
                                      },
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                  SizedBox(
                                    width: 248,
                                    child: ListView.builder(
                                      itemCount: _channels.length,
                                      itemBuilder: (_, i) {
                                        final ch = _channels[i];
                                        final name = '${ch['name'] ?? ''}';
                                        final logo = '${ch['logo'] ?? ''}';
                                        final sel = i == _chIdx;
                                        return Padding(
                                          padding: const EdgeInsets.only(bottom: 4),
                                          child: Material(
                                            color: sel ? const Color(0x2EFFFFFF) : Colors.transparent,
                                            borderRadius: BorderRadius.circular(8),
                                            child: InkWell(
                                              borderRadius: BorderRadius.circular(8),
                                              onTap: () => _playChannel(i),
                                              child: SizedBox(
                                                height: 48,
                                                child: Padding(
                                                  padding: const EdgeInsets.symmetric(horizontal: 8),
                                                  child: Row(
                                                    children: [
                                                      SizedBox(
                                                        width: 28,
                                                        child: Text(
                                                          '${i + 1}'.padLeft(2, '0'),
                                                          style: TextStyle(color: Colors.white.withOpacity(0.8), fontSize: 16),
                                                        ),
                                                      ),
                                                      const SizedBox(width: 12),
                                                      _LiveChannelLogo(name: name, logo: logo),
                                                      const SizedBox(width: 12),
                                                      Expanded(
                                                        child: Text(
                                                          name,
                                                          maxLines: 1,
                                                          overflow: TextOverflow.ellipsis,
                                                          style: const TextStyle(color: Colors.white, fontSize: 16),
                                                        ),
                                                      ),
                                                    ],
                                                  ),
                                                ),
                                              ),
                                            ),
                                          ),
                                        );
                                      },
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.stretch,
                                      children: [
                                        Padding(
                                          padding: const EdgeInsets.only(bottom: 6, left: 4),
                                          child: Text('EPG', style: TextStyle(color: Colors.white.withOpacity(0.7), fontSize: 13, fontWeight: FontWeight.w600)),
                                        ),
                                        if (_epgDays.length > 1)
                                          SizedBox(
                                            height: 34,
                                            child: ListView.separated(
                                              scrollDirection: Axis.horizontal,
                                              itemCount: _epgDays.length,
                                              separatorBuilder: (_, __) => const SizedBox(width: 6),
                                              itemBuilder: (_, i) {
                                                final d = '${_epgDays[i]['date'] ?? 'D$i'}';
                                                final label = d.length >= 10 ? d.substring(5, 10) : d;
                                                return AppPill(
                                                  label: label,
                                                  width: 96,
                                                  height: 32,
                                                  fontSize: 13,
                                                  selected: i == _dayIdx,
                                                  onTap: () {
                                                    final progs = (((_epgDays[i]['list'] as List?) ?? [])
                                                        .whereType<Map>()
                                                        .map((e) => Map<String, dynamic>.from(e))
                                                        .toList());
                                                    setState(() {
                                                      _dayIdx = i;
                                                      _programs = progs;
                                                    });
                                                  },
                                                );
                                              },
                                            ),
                                          ),
                                        const SizedBox(height: 6),
                                        Expanded(
                                          child: _programs.isEmpty
                                              ? const Center(child: Text('暂无节目单', style: TextStyle(color: Colors.white54, fontSize: 13)))
                                              : ListView.builder(
                                                  itemCount: _programs.length,
                                                  itemBuilder: (_, i) {
                                                    final p = _programs[i];
                                                    final now = p['now'] == true;
                                                    final catchup = p['catchup'] == true;
                                                    return Padding(
                                                      padding: const EdgeInsets.only(bottom: 4),
                                                      child: Material(
                                                        color: now ? const Color(0xD0C73C62) : const Color(0x9918161E),
                                                        borderRadius: BorderRadius.circular(6),
                                                        child: InkWell(
                                                          borderRadius: BorderRadius.circular(6),
                                                          onTap: catchup ? () => _playCatchup(i) : null,
                                                          child: Padding(
                                                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                                                            child: Text(
                                                              '${p['label'] ?? p['title'] ?? ''}${catchup ? ' · 回看' : ''}',
                                                              maxLines: 2,
                                                              overflow: TextOverflow.ellipsis,
                                                              style: TextStyle(
                                                                color: Colors.white.withOpacity(now ? 1 : 0.8),
                                                                fontSize: 12,
                                                              ),
                                                            ),
                                                          ),
                                                        ),
                                                      ),
                                                    );
                                                  },
                                                ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  if (_rightOpen)
                    Positioned(
                      right: 0,
                      top: 56,
                      bottom: 72,
                      child: MouseRegion(
                        onEnter: (_) => _cancelHideOverlays(),
                        onExit: (_) => _scheduleHideOverlays(),
                        child: Material(
                          color: const Color(0x99120A24),
                          child: SizedBox(
                            width: 280,
                            child: ListView(
                              padding: const EdgeInsets.all(14),
                              children: [
                                const Text('直播设置', style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w700)),
                                const SizedBox(height: 12),
                                AppPill(
                                  label: '上一频道',
                                  height: 40,
                                  onTap: () {
                                    final chs = _channels;
                                    if (chs.isEmpty) return;
                                    _playChannel(_chIdx <= 0 ? chs.length - 1 : _chIdx - 1);
                                  },
                                ),
                                const SizedBox(height: 8),
                                AppPill(
                                  label: '下一频道',
                                  height: 40,
                                  onTap: () {
                                    final chs = _channels;
                                    if (chs.isEmpty) return;
                                    _playChannel((_chIdx + 1) % chs.length);
                                  },
                                ),
                                const SizedBox(height: 8),
                                AppPill(
                                  label: '换线路 (${_line + 1}/$_lines)',
                                  height: 40,
                                  onTap: () {
                                    if (_chIdx < 0 || _lines <= 1) return;
                                    _playChannel(_chIdx, line: (_line + 1) % _lines);
                                  },
                                ),
                                const SizedBox(height: 8),
                                AppPill(label: '刷新 EPG', height: 40, onTap: _loadEpg),
                                const SizedBox(height: 8),
                                AppPill(label: '投屏', height: 40, onTap: () => unawaited(_cast())),
                                const SizedBox(height: 8),
                                AppPill(label: '迷你桌面播放', height: 40, onTap: () => unawaited(_enterMini())),
                                const SizedBox(height: 8),
                                AppPill(
                                  label: '播放器 · ${flutterPlayerLabel(_playerVal)}',
                                  height: 40,
                                  onTap: () => unawaited(_pickPlayer()),
                                ),
                                const SizedBox(height: 8),
                                AppPill(
                                  label: '解码 · $_decodeLabel',
                                  height: 40,
                                  onTap: () => unawaited(_pickDecode()),
                                ),
                                const SizedBox(height: 8),
                                StreamBuilder(
                                  stream: _playback.positionStream,
                                  builder: (context, _) {
                                    final vol = _playback.volume.clamp(0, 100).toDouble();
                                    return Column(
                                      crossAxisAlignment: CrossAxisAlignment.stretch,
                                      children: [
                                        Text('音量 ${vol.round()}', style: const TextStyle(color: Colors.white70)),
                                        Slider(
                                          value: vol,
                                          max: 100,
                                          onChanged: (v) => _playback.setVolume(v),
                                        ),
                                      ],
                                    );
                                  },
                                ),
                                const SizedBox(height: 8),
                                AppPill(label: '打开设置页', height: 40, onTap: () => goKotvPage(ref, KotvPage.settings)),
                                const SizedBox(height: 16),
                                const Text('直播源', style: TextStyle(color: Colors.white70)),
                                const SizedBox(height: 8),
                                for (var i = 0; i < _sources.length; i++)
                                  Padding(
                                    padding: const EdgeInsets.only(bottom: 6),
                                    child: AppPill(
                                      label: '${_sources[i]['name'] ?? _sources[i]['url']}',
                                      height: 36,
                                      fontSize: 13,
                                      selected: i == _srcIdx,
                                      onTap: () => _loadSource(i, autoPlay: true),
                                    ),
                                  ),
                                const SizedBox(height: 12),
                                AppPill(
                                  label: '配置直播源',
                                  height: 40,
                                  onTap: () async {
                                    await showAddLiveDialog(context, ref);
                                    await _bootstrap();
                                  },
                                ),
                                const SizedBox(height: 8),
                                AppPill(label: '关闭面板', height: 40, onTap: () => setState(() => _rightOpen = false)),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  // 底栏 info bar：台号 | logo | 名 | 节目 | 线路
                  if (!_catchup || !_catchupChrome)
                    Positioned(
                      left: 16,
                      right: 16,
                      bottom: _catchupChrome ? 88 : 12,
                      child: Material(
                        color: const Color(0xA6000000),
                        borderRadius: BorderRadius.circular(10),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                          child: Row(
                            children: [
                              Text(_channelNum, style: TextStyle(color: Colors.white.withOpacity(0.7), fontSize: 20)),
                              const SizedBox(width: 12),
                              _LiveChannelLogo(name: _title, logo: _currentLogo),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text(
                                      _title,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w600),
                                    ),
                                    if (_programLabel.isNotEmpty || _status.isNotEmpty)
                                      Text(
                                        _programLabel.isNotEmpty ? _programLabel : _status,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(color: Colors.white.withOpacity(0.7), fontSize: 13),
                                      ),
                                  ],
                                ),
                              ),
                              if (_lineLabel.isNotEmpty)
                                Text(_lineLabel, style: TextStyle(color: Colors.white.withOpacity(0.75), fontSize: 13)),
                            ],
                          ),
                        ),
                      ),
                    ),
                  if (_catchup && _catchupChrome)
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: MouseRegion(
                        onEnter: (_) => _catchupHideTimer?.cancel(),
                        onExit: (_) => _pulseCatchupChrome(),
                        child: LiveCatchupChrome(
                          player: _playback,
                          playerLabel: flutterPlayerLabel(_playerVal),
                          decodeLabel: _decodeLabel,
                          onCast: () => unawaited(_cast()),
                          onMini: () => unawaited(_enterMini()),
                          onPlayer: () => unawaited(_pickPlayer()),
                          onDecode: () => unawaited(_pickDecode()),
                        ),
                      ),
                    ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  /// 竖屏：顶栏 + 播放器(含控件) + 频道/EPG 切换。
  Widget _buildPortraitLive() {
    final p = KotvPalette.of(context);
    final chs = _channels;
    final title = _title.isNotEmpty ? _title : '直播';
    final showChrome = _portraitChrome || (_catchup && _catchupChrome);
    return Column(
      children: [
        LibraryTopBar(
          onBack: () => goKotvPage(ref, KotvPage.video),
          onSearch: () => goKotvPage(ref, KotvPage.search),
          onProfile: () => goKotvPage(ref, KotvPage.profile),
          onNews: () => showAppNews(context, remoteHint(ref)),
          title: '直播',
        ),
        AspectRatio(
          aspectRatio: 16 / 9,
          child: ColoredBox(
            color: Colors.black,
            child: Stack(
              fit: StackFit.expand,
              children: [
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => setState(() {
                    if (_catchup) {
                      _toggleCatchupChrome();
                    } else {
                      _portraitChrome = !_portraitChrome;
                    }
                  }),
                  child: _liveVideo(),
                ),
                if (_loading) const Center(child: CircularProgressIndicator(color: Colors.white)),
                if (_error != null)
                  Center(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Text(_error!, textAlign: TextAlign.center, style: const TextStyle(color: Colors.white70)),
                    ),
                  ),
                if (showChrome)
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: LiveCatchupChrome(
                      player: _playback,
                      playerLabel: flutterPlayerLabel(_playerVal),
                      decodeLabel: _decodeLabel,
                      onCast: () => unawaited(_cast()),
                      onMini: () => unawaited(_enterMini()),
                      onPlayer: () => unawaited(_pickPlayer()),
                      onDecode: () => unawaited(_pickDecode()),
                    ),
                  ),
              ],
            ),
          ),
        ),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
          color: p.catBar,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  _LiveChannelLogo(name: title, logo: _currentLogo, width: 40, height: 30),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '$_channelNum  $title',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: p.fg, fontSize: 15, fontWeight: FontWeight.w700),
                        ),
                        Text(
                          [
                            if (_programLabel.isNotEmpty) _programLabel,
                            if (_lineLabel.isNotEmpty) _lineLabel,
                            _status,
                          ].where((e) => e.isNotEmpty).join(' · '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: p.muted, fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    AppPill(
                      label: '上一台',
                      height: 32,
                      fontSize: 12,
                      onTap: () {
                        if (chs.isEmpty) return;
                        _playChannel(_chIdx <= 0 ? chs.length - 1 : _chIdx - 1);
                      },
                    ),
                    const SizedBox(width: 6),
                    AppPill(
                      label: '下一台',
                      height: 32,
                      fontSize: 12,
                      onTap: () {
                        if (chs.isEmpty) return;
                        _playChannel((_chIdx + 1) % chs.length);
                      },
                    ),
                    const SizedBox(width: 6),
                    AppPill(
                      label: _lines > 1 ? '线路 ${_line + 1}/$_lines' : '线路',
                      height: 32,
                      fontSize: 12,
                      onTap: () {
                        if (_chIdx < 0 || _lines <= 1) return;
                        _playChannel(_chIdx, line: (_line + 1) % _lines);
                      },
                    ),
                    const SizedBox(width: 6),
                    AppPill(label: '刷新EPG', height: 32, fontSize: 12, onTap: _loadEpg),
                    const SizedBox(width: 6),
                    AppPill(label: '投屏', height: 32, fontSize: 12, onTap: () => unawaited(_cast())),
                    const SizedBox(width: 6),
                    AppPill(label: '全屏', height: 32, fontSize: 12, onTap: () => unawaited(_enterLiveFullscreen())),
                    const SizedBox(width: 6),
                    AppPill(
                      label: flutterPlayerLabel(_playerVal),
                      height: 32,
                      fontSize: 12,
                      onTap: () => unawaited(_pickPlayer()),
                    ),
                    const SizedBox(width: 6),
                    AppPill(
                      label: '解码·$_decodeLabel',
                      height: 32,
                      fontSize: 12,
                      onTap: () => unawaited(_pickDecode()),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: AppPill(
                      label: '频道',
                      height: 34,
                      fontSize: 13,
                      selected: _portraitTab == 0,
                      onTap: () => setState(() => _portraitTab = 0),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: AppPill(
                      label: 'EPG节目单',
                      height: 34,
                      fontSize: 13,
                      selected: _portraitTab == 1,
                      onTap: () {
                        setState(() => _portraitTab = 1);
                        if (_programs.isEmpty && _chIdx >= 0) unawaited(_loadEpg());
                      },
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        Expanded(
          child: _portraitTab == 0 ? _portraitChannelPanel(p, chs) : _portraitEpgPanel(p),
        ),
      ],
    );
  }

  Widget _portraitChannelPanel(KotvPalette p, List<Map<String, dynamic>> chs) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          width: 88,
          child: ColoredBox(
            color: p.bottomNav.withOpacity(0.92),
            child: ListView.builder(
              padding: const EdgeInsets.fromLTRB(4, 4, 3, 4),
              itemCount: _groups.length,
              itemBuilder: (_, i) {
                final g = _groups[i];
                final locked = _groupLocked(i);
                final name = '${locked ? '🔒' : ''}${g['name'] ?? ''}';
                final sel = i == _groupIdx;
                return Padding(
                  padding: const EdgeInsets.only(bottom: 3),
                  child: Material(
                    color: sel ? p.selected : p.pillBg.withOpacity(0.7),
                    borderRadius: BorderRadius.circular(6),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(6),
                      onTap: () => _selectGroup(i),
                      child: Container(
                        width: double.infinity,
                        constraints: const BoxConstraints(minHeight: 28),
                        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 5),
                        alignment: Alignment.center,
                        child: Text(
                          name,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: sel ? Colors.white : p.fg,
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                            height: 1.15,
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.fromLTRB(3, 4, 6, 4),
            itemCount: chs.length,
            itemBuilder: (_, i) {
              final ch = chs[i];
              final name = '${ch['name'] ?? ''}';
              final logo = '${ch['logo'] ?? ''}';
              final sel = i == _chIdx;
              return Padding(
                padding: const EdgeInsets.only(bottom: 3),
                child: Material(
                  color: sel ? p.selected.withOpacity(0.28) : p.pillBg.withOpacity(0.55),
                  borderRadius: BorderRadius.circular(6),
                  child: InkWell(
                    borderRadius: BorderRadius.circular(6),
                    onTap: () => _playChannel(i),
                    child: SizedBox(
                      height: 36,
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 6),
                        child: Row(
                          children: [
                            SizedBox(
                              width: 22,
                              child: Text('${i + 1}'.padLeft(2, '0'), style: TextStyle(color: p.muted, fontSize: 11)),
                            ),
                            const SizedBox(width: 4),
                            _LiveChannelLogo(name: name, logo: logo, width: 28, height: 22),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: p.fg,
                                  fontSize: 12,
                                  fontWeight: sel ? FontWeight.w700 : FontWeight.w500,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _portraitEpgPanel(KotvPalette p) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_epgDays.length > 1)
          SizedBox(
            height: 40,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.fromLTRB(8, 6, 8, 4),
              itemCount: _epgDays.length,
              separatorBuilder: (_, __) => const SizedBox(width: 6),
              itemBuilder: (_, i) {
                final d = '${_epgDays[i]['date'] ?? 'D$i'}';
                final label = d.length >= 10 ? d.substring(5, 10) : d;
                return AppPill(
                  label: label,
                  width: 72,
                  height: 30,
                  fontSize: 12,
                  selected: i == _dayIdx,
                  onTap: () {
                    final progs = (((_epgDays[i]['list'] as List?) ?? [])
                        .whereType<Map>()
                        .map((e) => Map<String, dynamic>.from(e))
                        .toList());
                    setState(() {
                      _dayIdx = i;
                      _programs = progs;
                    });
                  },
                );
              },
            ),
          ),
        Expanded(
          child: _programs.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('暂无节目单', style: TextStyle(color: p.muted, fontSize: 14)),
                      const SizedBox(height: 10),
                      AppPill(label: '刷新 EPG', height: 34, fontSize: 13, selected: true, onTap: _loadEpg),
                    ],
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
                  itemCount: _programs.length,
                  itemBuilder: (_, i) {
                    final prog = _programs[i];
                    final now = prog['now'] == true;
                    final catchup = prog['catchup'] == true;
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Material(
                        color: now ? p.selected.withOpacity(0.9) : p.pillBg.withOpacity(0.7),
                        borderRadius: BorderRadius.circular(8),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(8),
                          onTap: catchup ? () => _playCatchup(i) : null,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    '${prog['label'] ?? prog['title'] ?? ''}',
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: now ? Colors.white : p.fg,
                                      fontSize: 13,
                                      fontWeight: now ? FontWeight.w700 : FontWeight.w500,
                                    ),
                                  ),
                                ),
                                if (catchup)
                                  Text('回看', style: TextStyle(color: p.primary, fontSize: 12, fontWeight: FontWeight.w700)),
                                if (now && !catchup)
                                  const Text('正在播出', style: TextStyle(color: Colors.white70, fontSize: 12)),
                              ],
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class _LiveChannelLogo extends StatelessWidget {
  const _LiveChannelLogo({required this.name, required this.logo, this.width = 48, this.height = 36});

  final String name;
  final String logo;
  final double width;
  final double height;

  static const _palette = <Color>[
    Color(0xFFE53935),
    Color(0xFFD81B60),
    Color(0xFF8E24AA),
    Color(0xFF5E35B1),
    Color(0xFF3949AB),
    Color(0xFF1E88E5),
    Color(0xFF039BE5),
    Color(0xFF00ACC1),
    Color(0xFF00897B),
    Color(0xFF43A047),
    Color(0xFF7CB342),
    Color(0xFFC0CA33),
    Color(0xFFFB8C00),
    Color(0xFFF4511E),
    Color(0xFF6D4C41),
    Color(0xFF546E7A),
  ];

  Color get _bg {
    final letter = _letter;
    var h = 0;
    for (final r in letter.runes) {
      h = 31 * h + r;
    }
    if (h < 0) h = -h;
    return _palette[h % _palette.length];
  }

  String get _letter {
    var s = name.trimLeft();
    if (s.startsWith('★')) s = s.substring(1).trimLeft();
    if (s.isEmpty) return '！';
    return String.fromCharCode(s.runes.first);
  }

  bool get _httpLogo {
    final s = logo.trim();
    return s.startsWith('http://') || s.startsWith('https://') || s.startsWith('proxy://') || s.startsWith('data:');
  }

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(4),
      child: SizedBox(
        width: width,
        height: height,
        child: _httpLogo
            ? Image.network(
                logo.trim(),
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => _fallback(),
              )
            : _fallback(),
      ),
    );
  }

  Widget _fallback() {
    return ColoredBox(
      color: _bg,
      child: Center(
        child: Text(_letter, style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600)),
      ),
    );
  }
}
