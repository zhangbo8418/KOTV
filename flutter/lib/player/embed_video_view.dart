import 'package:flutter/material.dart';

import 'kotv_playback.dart';

/// VLC Texture 直出。
class EmbedVideoView extends StatelessWidget {
  const EmbedVideoView({
    super.key,
    required this.playback,
    this.fit = BoxFit.contain,
    this.aspectRatio,
  });

  final EngineVlcPlayback playback;
  final BoxFit fit;
  final double? aspectRatio;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: playback,
      builder: (context, _) {
        Widget content;
        final texId = playback.textureId;
        if (!playback.useTexture || texId == null || texId < 0) {
          content = const ColoredBox(
            color: Colors.black,
            child: Center(
              child: Text('内置 VLC 加载中…', style: TextStyle(color: Colors.white54)),
            ),
          );
        } else {
          final w = playback.width > 0 ? playback.width.toDouble() : 16.0;
          final h = playback.height > 0 ? playback.height.toDouble() : 9.0;
          content = ColoredBox(
            color: Colors.black,
            child: SizedBox.expand(
              child: FittedBox(
                fit: fit,
                child: SizedBox(
                  width: w,
                  height: h,
                  child: Texture(textureId: texId, filterQuality: FilterQuality.low),
                ),
              ),
            ),
          );
        }
        final ratio = aspectRatio;
        if (ratio == null || ratio <= 0) return content;
        return LayoutBuilder(
          builder: (context, c) {
            var w = c.maxWidth;
            var h = w / ratio;
            if (h > c.maxHeight) {
              h = c.maxHeight;
              w = h * ratio;
            }
            return ColoredBox(
              color: Colors.black,
              child: Center(child: SizedBox(width: w, height: h, child: content)),
            );
          },
        );
      },
    );
  }
}
