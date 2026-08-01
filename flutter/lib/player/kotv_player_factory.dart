import 'package:flutter/material.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'embed_video_view.dart';
import 'exo_playback.dart';
import 'ijk_playback.dart';
import 'kotv_playback.dart';
import 'kotv_platform.dart';

/// 根据播放器 ID 创建页内后端（不负责复用；由页面缓存实例）。
KotvPlayback createKotvPlayback(String playerVal) {
  switch (kotvEmbedBackend(playerVal)) {
    case KotvEmbedBackend.vlc:
      return EngineVlcPlayback();
    case KotvEmbedBackend.exo:
      return ExoPlayback();
    case KotvEmbedBackend.ijk:
      return IjkPlayback();
    case KotvEmbedBackend.mpv:
      throw StateError('MPV 请用 MediaKitPlayback(Player()) 复用');
  }
}

/// 页内画面：按后端选择 Texture / VideoPlayer / FijkView / media_kit Video。
Widget kotvPlaybackView({
  required String playerVal,
  required KotvPlayback playback,
  MediaKitPlayback? mpv,
  BoxFit fit = BoxFit.contain,
}) {
  switch (kotvEmbedBackend(playerVal)) {
    case KotvEmbedBackend.vlc:
      if (playback is EngineVlcPlayback) {
        return EmbedVideoView(playback: playback);
      }
      return const ColoredBox(color: Colors.black);
    case KotvEmbedBackend.exo:
      if (playback is ExoPlayback) {
        return playback.buildView(fit: fit);
      }
      return const ColoredBox(color: Colors.black);
    case KotvEmbedBackend.ijk:
      if (playback is IjkPlayback) {
        return playback.buildView(fit: fit);
      }
      return const ColoredBox(color: Colors.black);
    case KotvEmbedBackend.mpv:
      final m = mpv ?? (playback is MediaKitPlayback ? playback : null);
      if (m == null) return const ColoredBox(color: Colors.black);
      return Video(controller: m.controller, controls: NoVideoControls, fit: fit);
  }
}
