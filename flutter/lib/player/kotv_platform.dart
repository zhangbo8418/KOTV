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

/// 是否 Windows 7（字体/解码等兼容用；直播默认与其它 PC 相同，均为 MPV）。
bool kotvIsWindows7() {
  if (kIsWeb || !Platform.isWindows) return false;
  final v = Platform.operatingSystemVersion.toLowerCase();
  if (v.contains('windows 7') || v.contains('win7')) return true;
  return RegExp(r'(^|[^\d])6\.1([^\d]|$)').hasMatch(v);
}

bool kotvIsAndroid() => !kIsWeb && Platform.isAndroid;
bool kotvIsIOS() => !kIsWeb && Platform.isIOS;

/// 对齐 TV `select_render`：Surface=0（默认 HDR），Texture=1。
String kotvNormalizePlayerRender(String raw) {
  switch (raw.trim().toLowerCase()) {
    case 'texture':
    case 'textureview':
    case '1':
      return 'texture';
    default:
      return 'surface';
  }
}

String kotvPlayerRenderLabel(String raw) =>
    kotvNormalizePlayerRender(raw) == 'texture' ? 'Texture' : 'Surface';

/// Surface/Texture 对齐 TV `PlayerView.setRender`：Android 内置 Exo 与 MPV 共用。
bool kotvPlayerRenderApplies(String playerVal) {
  if (!kotvIsAndroid()) return false;
  final b = kotvEmbedBackend(playerVal);
  return b == KotvEmbedBackend.exo || b == KotvEmbedBackend.mpv;
}

/// 点播默认：Web=HTML5；Android=Exo；桌面/iOS=内置 MPV。
String kotvDefaultVodPlayer() {
  if (kIsWeb) return 'innie#html';
  if (kotvIsAndroid()) return 'innie#exo';
  return 'innie#mpv';
}

/// 直播默认：Web=HTML5；Android=Exo；桌面/iOS=内置 MPV。
String kotvDefaultLivePlayer() {
  if (kIsWeb) return 'innie#html';
  if (kotvIsAndroid()) return 'innie#exo';
  return 'innie#mpv';
}

String kotvClampPlayerVal(String raw, {required bool live}) {
  final v = raw.trim();
  final opts = live ? kotvLivePlayerOptions() : kotvVodPlayerOptions();
  for (final o in opts) {
    if (o.$2 == v) return v;
  }
  return live ? kotvDefaultLivePlayer() : kotvDefaultVodPlayer();
}

bool kotvCanSwitchPlayer({required bool live}) =>
    (live ? kotvLivePlayerOptions() : kotvVodPlayerOptions()).length > 1;

enum KotvEmbedBackend { mpv, fvp, exo, html, art, xg, zw }

KotvEmbedBackend kotvEmbedBackend(String playerVal) {
  switch (playerVal.trim()) {
    case 'innie#html':
      return KotvEmbedBackend.html;
    case 'innie#art':
      return KotvEmbedBackend.art;
    case 'innie#xg':
      return KotvEmbedBackend.xg;
    case 'innie#zw':
      return KotvEmbedBackend.zw;
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
      ('ArtPlayer', 'innie#art'),
      ('西瓜播放器（xgplayer）', 'innie#xg'),
      ('全能播放器（ZWPlayer）', 'innie#zw'),
    ];
  }
  if (kotvIsAndroid()) {
    return const [
      ('内置 ExoPlayer（默认）', 'innie#exo'),
      ('内置 MPV', 'innie#mpv'),
      ('内置 FVP', 'innie#fvp'),
    ];
  }
  if (kotvIsIOS()) {
    return const [
      ('内置 MPV（默认）', 'innie#mpv'),
      ('内置 FVP', 'innie#fvp'),
      ('浏览器播放（HTML5）', 'innie#html'),
    ];
  }
  return [
    ('内置 MPV（默认）', 'innie#mpv'),
    ('内置 FVP', 'innie#fvp'),
    ('外部 MPV', 'outie#mpv'),
    ('外部 VLC', 'outie#vlc'),
    if (Platform.isMacOS) ('IINA', 'outie#iina'),
  ];
}

List<(String, String)> kotvLivePlayerOptions() {
  if (kIsWeb) {
    return const [
      ('浏览器播放（HTML5）（默认）', 'innie#html'),
      ('ArtPlayer', 'innie#art'),
      ('西瓜播放器（xgplayer）', 'innie#xg'),
      ('全能播放器（ZWPlayer）', 'innie#zw'),
    ];
  }
  if (kotvIsAndroid()) {
    return const [
      ('内置 ExoPlayer（默认）', 'innie#exo'),
      ('内置 MPV', 'innie#mpv'),
      ('内置 FVP', 'innie#fvp'),
    ];
  }
  if (kotvIsIOS()) {
    return const [
      ('内置 MPV（默认）', 'innie#mpv'),
      ('内置 FVP', 'innie#fvp'),
      ('浏览器播放（HTML5）', 'innie#html'),
    ];
  }
  return [
    ('内置 MPV（默认）', 'innie#mpv'),
    ('内置 FVP', 'innie#fvp'),
    ('外部 MPV', 'outie#mpv'),
    ('外部 VLC', 'outie#vlc'),
    if (Platform.isMacOS) ('IINA', 'outie#iina'),
  ];
}
