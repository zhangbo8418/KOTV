import '../util/kotv_io.dart';

import 'package:flutter/foundation.dart';

/// 弹窗宿主平台（发给脚本用）：以 Flutter 客户端为准，不是引擎所在机器。
String kotvHostPlatform() {
  if (kIsWeb) return 'web';
  if (Platform.isAndroid) return 'android';
  if (Platform.isIOS) return 'ios';
  if (Platform.isMacOS) return 'macos';
  if (Platform.isWindows) return 'windows';
  if (Platform.isLinux) return 'linux';
  return 'unknown';
}

bool kotvIsDesktop() {
  if (kIsWeb) return false;
  return Platform.isMacOS || Platform.isWindows || Platform.isLinux;
}

/// Win7：media_kit 偶发卡死；失败应回退 fvp。
bool kotvIsWindows7() {
  if (kIsWeb || !Platform.isWindows) return false;
  final v = Platform.operatingSystemVersion.toLowerCase();
  if (v.contains('windows 7') || v.contains('win7')) return true;
  return RegExp(r'(^|[^\d])6\.1([^\d]|$)').hasMatch(v);
}

bool kotvIsAndroid() => !kIsWeb && Platform.isAndroid;
bool kotvIsIOS() => !kIsWeb && Platform.isIOS;

/// 旧配置迁移：vlc→mpv，ijk→fvp。
String kotvMigratePlayerVal(String raw) {
  switch (raw.trim()) {
    case 'innie#vlc':
    case 'outie#vlc':
      return 'innie#mpv';
    case 'innie#ijk':
      return 'innie#fvp';
    default:
      return raw.trim();
  }
}

/// 点播默认：Web=HTML5；Android=Exo；iOS=FVP；其它=MPV。
String kotvDefaultVodPlayer() {
  if (kIsWeb) return 'innie#html';
  if (kotvIsAndroid()) return 'innie#exo';
  if (kotvIsIOS()) return 'innie#fvp';
  return 'innie#mpv';
}

/// 直播默认：Web=HTML5；Android=Exo；iOS=FVP；桌面=MPV（含 Windows）。
String kotvDefaultLivePlayer() {
  if (kIsWeb) return 'innie#html';
  if (kotvIsAndroid()) return 'innie#exo';
  if (kotvIsIOS()) return 'innie#fvp';
  return 'innie#mpv';
}

String kotvClampPlayerVal(String raw, {required bool live}) {
  final v = kotvMigratePlayerVal(raw);
  final opts = live ? kotvLivePlayerOptions() : kotvVodPlayerOptions();
  for (final o in opts) {
    if (o.$2 == v) return v;
  }
  return live ? kotvDefaultLivePlayer() : kotvDefaultVodPlayer();
}

bool kotvCanSwitchPlayer({required bool live}) =>
    (live ? kotvLivePlayerOptions() : kotvVodPlayerOptions()).length > 1;

enum KotvEmbedBackend { mpv, fvp, exo, html, vp }

KotvEmbedBackend kotvEmbedBackend(String playerVal) {
  switch (kotvMigratePlayerVal(playerVal)) {
    case 'innie#html':
      return KotvEmbedBackend.html;
    case 'innie#vp':
      return KotvEmbedBackend.vp;
    case 'innie#fvp':
      return KotvEmbedBackend.fvp;
    case 'innie#exo':
      return KotvEmbedBackend.exo;
    case 'innie#mpv':
    default:
      // Web 无 MPV/Exo/FVP；非法值由 clamp 纠正，此处兜底 HTML。
      if (kIsWeb) return KotvEmbedBackend.html;
      return KotvEmbedBackend.mpv;
  }
}

List<(String, String)> kotvVodPlayerOptions() {
  if (kIsWeb) {
    return const [
      ('浏览器播放（HTML5）（默认）', 'innie#html'),
      ('video_player', 'innie#vp'),
    ];
  }
  if (kotvIsAndroid()) {
    return const [
      ('内置 ExoPlayer（默认）', 'innie#exo'),
      ('内置 MPV', 'innie#mpv'),
      ('内置 FVP（零拷贝）', 'innie#fvp'),
    ];
  }
  if (kotvIsIOS()) {
    return const [
      ('内置 FVP（默认）', 'innie#fvp'),
      ('内置 MPV', 'innie#mpv'),
      ('浏览器播放（HTML5）', 'innie#html'),
    ];
  }
  return [
    ('内置 MPV（默认）', 'innie#mpv'),
    ('内置 FVP（零拷贝）', 'innie#fvp'),
    ('外部 MPV', 'outie#mpv'),
    if (Platform.isMacOS) ('IINA', 'outie#iina'),
  ];
}

List<(String, String)> kotvLivePlayerOptions() {
  if (kIsWeb) {
    return const [
      ('浏览器播放（HTML5）（默认）', 'innie#html'),
      ('video_player', 'innie#vp'),
    ];
  }
  if (kotvIsAndroid()) {
    return const [
      ('内置 ExoPlayer（默认）', 'innie#exo'),
      ('内置 MPV', 'innie#mpv'),
      ('内置 FVP（零拷贝）', 'innie#fvp'),
    ];
  }
  if (kotvIsIOS()) {
    return const [
      ('内置 FVP（默认）', 'innie#fvp'),
      ('内置 MPV', 'innie#mpv'),
      ('浏览器播放（HTML5）', 'innie#html'),
    ];
  }
  return [
    ('内置 MPV（默认）', 'innie#mpv'),
    ('内置 FVP（零拷贝）', 'innie#fvp'),
    ('外部 MPV', 'outie#mpv'),
    if (Platform.isMacOS) ('IINA', 'outie#iina'),
  ];
}
