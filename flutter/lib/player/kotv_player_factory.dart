import 'package:flutter/material.dart';

import 'art_playback.dart';
import 'exo_playback.dart';
import 'fvp_playback.dart';
import 'html_playback.dart';
import 'kotv_playback.dart';
import 'kotv_platform.dart';
import 'native_mpv_playback.dart';
import 'xg_playback.dart';
import 'zw_playback.dart';

/// 根据播放器 ID 创建页内后端（不负责复用；由页面缓存实例）。
KotvPlayback createKotvPlayback(String playerVal) {
  switch (kotvEmbedBackend(playerVal)) {
    case KotvEmbedBackend.html:
      return HtmlPlayback();
    case KotvEmbedBackend.art:
      return ArtPlayback();
    case KotvEmbedBackend.xg:
      return XgPlayback();
    case KotvEmbedBackend.zw:
      return ZwPlayback();
    case KotvEmbedBackend.fvp:
      return FvpPlayback();
    case KotvEmbedBackend.exo:
      return ExoPlayback();
    case KotvEmbedBackend.mpv:
      return NativeMpvPlayback();
  }
}

/// 页内画面：按后端选择 PlatformView / Texture / HTML。
Widget kotvPlaybackView({
  required String playerVal,
  required KotvPlayback playback,
  NativeMpvPlayback? mpv,
  BoxFit fit = BoxFit.contain,
}) {
  switch (kotvEmbedBackend(playerVal)) {
    case KotvEmbedBackend.html:
      if (playback is HtmlPlayback) return playback.buildView(fit: fit);
      return const ColoredBox(color: Colors.black);
    case KotvEmbedBackend.art:
      if (playback is ArtPlayback) return playback.buildView(fit: fit);
      return const ColoredBox(color: Colors.black);
    case KotvEmbedBackend.xg:
      if (playback is XgPlayback) return playback.buildView(fit: fit);
      return const ColoredBox(color: Colors.black);
    case KotvEmbedBackend.zw:
      if (playback is ZwPlayback) return playback.buildView(fit: fit);
      return const ColoredBox(color: Colors.black);
    case KotvEmbedBackend.fvp:
      if (playback is FvpPlayback) return playback.buildView(fit: fit);
      return const ColoredBox(color: Colors.black);
    case KotvEmbedBackend.exo:
      if (playback is ExoPlayback) return playback.buildView(fit: fit);
      return const ColoredBox(color: Colors.black);
    case KotvEmbedBackend.mpv:
      final m = mpv ?? (playback is NativeMpvPlayback ? playback : null);
      if (m == null) return const ColoredBox(color: Colors.black);
      return m.buildView(fit: fit);
  }
}
