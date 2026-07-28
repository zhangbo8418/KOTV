import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../providers.dart';
import '../remote/remote_bridge.dart';
import '../theme/kotv_theme.dart';

class PlayerScreen extends ConsumerStatefulWidget {
  const PlayerScreen({
    super.key,
    required this.title,
    required this.url,
    this.onNext,
    this.onPrev,
  });

  final String title;
  final String url;
  final VoidCallback? onNext;
  final VoidCallback? onPrev;

  @override
  ConsumerState<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends ConsumerState<PlayerScreen> {
  late final Player _player = Player();
  late final VideoController _controller = VideoController(_player);
  Timer? _reportTimer;
  RemoteBridge? _bridge;

  @override
  void initState() {
    super.initState();
    _player.open(Media(widget.url));
    _reportTimer = Timer.periodic(const Duration(seconds: 2), (_) => _report());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _bridge = ref.read(remoteBridgeProvider);
      if (_bridge != null) {
        _bridge!.onControl = _onRemoteControl;
      }
      _report(state: 'playing');
    });
  }

  Future<void> _report({String? state}) async {
    final bridge = _bridge ?? ref.read(remoteBridgeProvider);
    if (bridge == null) return;
    final pos = _player.state.position.inMilliseconds;
    final dur = _player.state.duration.inMilliseconds;
    final playing = _player.state.playing;
    await bridge.reportMedia(
      state: state ?? (playing ? 'playing' : 'paused'),
      title: widget.title,
      url: widget.url,
      positionMs: pos,
      durationMs: dur,
    );
  }

  void _onRemoteControl(String type, int seekMs) {
    switch (type) {
      case 'play':
        _player.play();
        break;
      case 'pause':
        _player.pause();
        break;
      case 'toggle':
        _player.playOrPause();
        break;
      case 'stop':
        _player.stop();
        if (mounted) Navigator.of(context).maybePop();
        break;
      case 'seek':
        if (seekMs >= 0) {
          _player.seek(Duration(milliseconds: seekMs));
        }
        break;
      case 'back10':
        final p = _player.state.position - const Duration(seconds: 10);
        _player.seek(p.isNegative ? Duration.zero : p);
        break;
      case 'forward10':
        _player.seek(_player.state.position + const Duration(seconds: 10));
        break;
      case 'replay':
        _player.seek(Duration.zero);
        _player.play();
        break;
      case 'next':
        widget.onNext?.call();
        break;
      case 'prev':
        widget.onPrev?.call();
        break;
    }
    _report();
  }

  @override
  void dispose() {
    _reportTimer?.cancel();
    _bridge?.reportMedia(state: 'idle', title: '未播放');
    if (_bridge?.onControl == _onRemoteControl) {
      _bridge?.onControl = null;
    }
    _player.dispose();
    super.dispose();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.select ||
        key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.space ||
        key == LogicalKeyboardKey.mediaPlayPause) {
      _player.playOrPause();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowLeft || key == LogicalKeyboardKey.mediaRewind) {
      final p = _player.state.position - const Duration(seconds: 10);
      _player.seek(p.isNegative ? Duration.zero : p);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowRight || key == LogicalKeyboardKey.mediaFastForward) {
      _player.seek(_player.state.position + const Duration(seconds: 10));
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.goBack || key == LogicalKeyboardKey.escape) {
      Navigator.of(context).maybePop();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      widget.onPrev?.call();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowDown) {
      widget.onNext?.call();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      autofocus: true,
      onKeyEvent: _onKey,
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          fit: StackFit.expand,
          children: [
            Center(
              child: Video(
                controller: _controller,
                controls: AdaptiveVideoControls,
              ),
            ),
            Positioned(
              left: 12,
              top: MediaQuery.paddingOf(context).top + 8,
              child: TvFocus(
                onPressed: () => Navigator.of(context).maybePop(),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: Colors.black54,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.arrow_back, size: 18),
                      SizedBox(width: 6),
                      Text('返回'),
                    ],
                  ),
                ),
              ),
            ),
            Positioned(
              left: 16,
              right: 16,
              bottom: 24,
              child: Text(
                widget.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white70, fontSize: 14),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
