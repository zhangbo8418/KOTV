import '../util/kotv_io.dart';

import 'package:flutter/foundation.dart';

/// 弹窗宿主平台（发给脚本用）：以 Flutter 客户端为准，不是引擎所在机器。
/// iOS 连远程引擎时，脚本仍应收到 `ios`。
String kotvHostPlatform() {
  if (kIsWeb) return 'web';
  if (Platform.isAndroid) return 'android';
  if (Platform.isIOS) return 'ios';
  if (Platform.isMacOS) return 'macos';
  if (Platform.isWindows) return 'windows';
  if (Platform.isLinux) return 'linux';
  return 'unknown';
}

/// 桌面端（鼠标/窗口）；与手机/TV 的默认焦点框策略不同。
bool kotvIsDesktop() {
  if (kIsWeb) return false;
  return Platform.isMacOS || Platform.isWindows || Platform.isLinux;
}

/// Win7 实验线：media_kit/libmpv 在部分机型上会在创建 Player / 开播时卡死 UI。
bool kotvIsWindows7() {
  if (kIsWeb || !Platform.isWindows) return false;
  final v = Platform.operatingSystemVersion.toLowerCase();
  if (v.contains('windows 7') || v.contains('win7')) return true;
  // 兼容仅返回内部版本号的环境（6.1 = Win7）。
  return RegExp(r'(^|[^\d])6\.1([^\d]|$)').hasMatch(v);
}

bool kotvIsAndroid() => !kIsWeb && Platform.isAndroid;

/// 点播默认：Web=HTML5；Android=Exo；其它=MPV。
String kotvDefaultVodPlayer() {
  if (kIsWeb) return 'innie#html';
  if (kotvIsAndroid()) return 'innie#exo';
  return 'innie#mpv';
}

/// 直播默认：Web=HTML5；Android=Exo；Windows=VLC；其它=MPV。
String kotvDefaultLivePlayer() {
  if (kIsWeb) return 'innie#html';
  if (kotvIsAndroid()) return 'innie#exo';
  if (!kIsWeb && Platform.isWindows) return 'innie#vlc';
  return 'innie#mpv';
}

/// 页内播放器后端种类。
enum KotvEmbedBackend { mpv, vlc, exo, ijk, html }

KotvEmbedBackend kotvEmbedBackend(String playerVal) {
  if (kIsWeb) return KotvEmbedBackend.html;
  switch (playerVal.trim()) {
    case 'innie#html':
      return KotvEmbedBackend.html;
    case 'innie#vlc':
      return KotvEmbedBackend.vlc;
    case 'innie#exo':
      return KotvEmbedBackend.exo;
    case 'innie#ijk':
      return KotvEmbedBackend.ijk;
    case 'innie#mpv':
    default:
      return KotvEmbedBackend.mpv;
  }
}

/// 设置页 / 页内切换：按平台分流选项。
List<(String, String)> kotvVodPlayerOptions() {
  if (kIsWeb) {
    return const [('浏览器播放（HTML5）', 'innie#html')];
  }
  if (kotvIsAndroid()) {
    return const [
      ('内置 ExoPlayer（默认）', 'innie#exo'),
      ('内置 MPV', 'innie#mpv'),
      ('内置 ijk', 'innie#ijk'),
    ];
  }
  return const [
    ('内置 MPV（默认）', 'innie#mpv'),
    ('内置 VLC', 'innie#vlc'),
    ('外部 VLC', 'outie#vlc'),
    ('外部 MPV', 'outie#mpv'),
    ('IINA', 'outie#iina'),
  ];
}

List<(String, String)> kotvLivePlayerOptions() {
  if (kIsWeb) {
    return const [('浏览器播放（HTML5）', 'innie#html')];
  }
  if (kotvIsAndroid()) {
    return const [
      ('内置 ExoPlayer（默认）', 'innie#exo'),
      ('内置 MPV', 'innie#mpv'),
      ('内置 ijk', 'innie#ijk'),
    ];
  }
  final win = !kIsWeb && Platform.isWindows;
  return [
    ('内置 MPV${!win ? '（默认）' : ''}', 'innie#mpv'),
    ('内置 VLC${win ? '（默认）' : ''}', 'innie#vlc'),
    ('外部 VLC', 'outie#vlc'),
    ('外部 MPV', 'outie#mpv'),
    if (!kIsWeb && Platform.isMacOS) ('IINA', 'outie#iina'),
  ];
}
