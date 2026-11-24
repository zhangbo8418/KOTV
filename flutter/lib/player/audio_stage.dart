import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../widgets/kotv_network_image.dart';
import 'kotv_platform.dart';
import 'kotv_playback.dart';

/// 无视频尺寸且非纯音频时，Android Hybrid 才需要盖黑防叠影。
bool kotvNeedsBlankSurfaceCover(KotvPlayback pb) =>
    !pb.isAudioOnlyContent && pb.width <= 0 && pb.height <= 0;

/// Android Hybrid 视频栈上的 Flutter 黑盖（解析/无帧/起播缓冲）。
/// MediaOverlay 镂空仍靠原生 clearVideoLayer；本层挡 Texture 与盖不住时的叠影。
Widget kotvAndroidSurfaceBlankCover({
  required KotvPlayback playback,
  required bool parsing,
  bool keepLastFrame = false,
}) {
  if (!kotvIsAndroid()) return const SizedBox.shrink();
  return ListenableBuilder(
    listenable: playback,
    builder: (context, _) {
      final noFrame = kotvNeedsBlankSurfaceCover(playback);
      final startBuf = !playback.playing && playback.buffering;
      final cover = parsing ||
          (!keepLastFrame && noFrame) ||
          (!keepLastFrame && startBuf);
      if (!cover) return const SizedBox.shrink();
      return const IgnorePointer(child: ColoredBox(color: Colors.black));
    },
  );
}

/// 纯音频封面/动效叠层：只重建本层，不重建底层 Texture。
/// 不在此画标题——详情顶栏/正文、全屏顶栏、直播台名已有片名，避免小画幅里标题压住底栏控件。
Widget kotvAudioStageOverlay({
  required KotvPlayback playback,
  String coverUrl = '',
}) {
  return ListenableBuilder(
    listenable: playback,
    builder: (context, _) {
      if (!playback.isAudioOnlyContent) return const SizedBox.shrink();
      return IgnorePointer(
        child: KotvAudioStage(
          playing: playback.playing,
          coverUrl: coverUrl,
        ),
      );
    },
  );
}

/// 纯音频时盖在视频槽上：有封面用封面，否则呼吸光晕，避免黑屏。
class KotvAudioStage extends StatefulWidget {
  const KotvAudioStage({
    super.key,
    required this.playing,
    this.coverUrl = '',
  });

  final bool playing;
  final String coverUrl;

  @override
  State<KotvAudioStage> createState() => _KotvAudioStageState();
}

class _KotvAudioStageState extends State<KotvAudioStage> with SingleTickerProviderStateMixin {
  late final AnimationController _pulse;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(vsync: this, duration: const Duration(milliseconds: 2400));
    if (widget.playing) {
      _pulse.repeat(reverse: true);
    }
  }

  @override
  void didUpdateWidget(covariant KotvAudioStage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.playing == oldWidget.playing) return;
    if (widget.playing) {
      _pulse.repeat(reverse: true);
    } else {
      _pulse.stop();
      _pulse.value = 0.35;
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cover = widget.coverUrl.trim();
    return ColoredBox(
      color: const Color(0xFF141018),
      child: Stack(
        fit: StackFit.expand,
        children: [
          AnimatedBuilder(
            animation: _pulse,
            builder: (context, _) {
              final t = widget.playing ? _pulse.value : 0.35;
              return CustomPaint(
                painter: _AudioGlowPainter(t: t),
              );
            },
          ),
          LayoutBuilder(
            builder: (context, c) {
              // 手机 16:9 槽约 200px 高；碟片随槽缩放，避免撑出槽外压住底栏。
              final side = (math.min(c.maxWidth, c.maxHeight) * 0.55).clamp(72.0, 168.0);
              return Center(
                child: _CoverDisc(
                  coverUrl: cover,
                  playing: widget.playing,
                  pulse: _pulse,
                  size: side,
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}

class _CoverDisc extends StatelessWidget {
  const _CoverDisc({
    required this.coverUrl,
    required this.playing,
    required this.pulse,
    required this.size,
  });

  final String coverUrl;
  final bool playing;
  final Animation<double> pulse;
  final double size;

  @override
  Widget build(BuildContext context) {
    final iconSize = (size * 0.33).clamp(28.0, 56.0);
    return AnimatedBuilder(
      animation: pulse,
      builder: (context, child) {
        final scale = playing ? 1.0 + pulse.value * 0.04 : 1.0;
        return Transform.scale(scale: scale, child: child);
      },
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              color: Color.fromRGBO(72, 160, 200, playing ? 0.45 : 0.22),
              blurRadius: playing ? 28 : 16,
              spreadRadius: 2,
            ),
          ],
        ),
        clipBehavior: Clip.antiAlias,
        child: coverUrl.isEmpty
            ? ColoredBox(
                color: const Color(0xFF2A3340),
                child: Icon(Icons.audiotrack_rounded, color: const Color(0xCCFFFFFF), size: iconSize),
              )
            : KotvNetworkImage(
                coverUrl,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => ColoredBox(
                  color: const Color(0xFF2A3340),
                  child: Icon(Icons.audiotrack_rounded, color: const Color(0xCCFFFFFF), size: iconSize),
                ),
              ),
      ),
    );
  }
}

class _AudioGlowPainter extends CustomPainter {
  _AudioGlowPainter({required this.t});

  final double t;

  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, size.height / 2);
    final base = math.min(size.width, size.height) * 0.18;
    for (var i = 0; i < 3; i++) {
      final r = base * (1.6 + i * 0.85) * (0.92 + t * 0.16);
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2
        ..color = Color.fromRGBO(90, 160, 190, (0.22 - i * 0.05).clamp(0.04, 0.22));
      canvas.drawCircle(c, r, paint);
    }
    final wash = Paint()
      ..shader = RadialGradient(
        colors: [
          Color.fromRGBO(70, 130, 160, 0.18 + t * 0.1),
          const Color(0x00141018),
        ],
      ).createShader(Rect.fromCircle(center: c, radius: size.shortestSide * 0.55));
    canvas.drawRect(Offset.zero & size, wash);
  }

  @override
  bool shouldRepaint(covariant _AudioGlowPainter oldDelegate) => oldDelegate.t != t;
}
