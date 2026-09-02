import 'package:flutter/material.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'art_playback.dart';
import 'exo_playback.dart';
import 'fvp_playback.dart';
import 'fvp_register.dart';
import 'html_playback.dart';
import 'kotv_playback.dart';
import 'kotv_platform.dart';
import 'media_kit_playback.dart';
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
      kotvEnsureFvpRegistered();
      return FvpPlayback();
    case KotvEmbedBackend.exo:
      return ExoPlayback();
    case KotvEmbedBackend.mpv:
      if (kotvIsAndroid()) return NativeMpvPlayback();
      throw StateError('MPV 请用 MediaKitPlayback(Player()) 复用');
  }
}

/// 页内画面：Android 原生 MPV PlatformView；桌面/Windows/iOS media_kit Video；FVP 各平台独立。
Widget kotvPlaybackView({
  required String playerVal,
  required KotvPlayback playback,
  KotvPlayback? mpv,
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
      final m = mpv ?? playback;
      if (m is NativeMpvPlayback) return m.buildView(fit: fit);
      if (m is MediaKitPlayback) {
        return Video(
          controller: m.controller,
          controls: NoVideoControls,
          fit: fit,
          wakelock: false,
        );
      }
      return const ColoredBox(color: Colors.black);
  }
}
