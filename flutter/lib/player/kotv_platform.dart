import 'dart:io';

import 'package:flutter/foundation.dart';

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

/// 点播默认播放器：全平台（含 Windows / Win7）默认内置 MPV。
String kotvDefaultVodPlayer() => 'innie#mpv';

/// 直播默认播放器：Windows（含 Win7）默认内置 VLC，其它平台 MPV。
String kotvDefaultLivePlayer() {
  if (!kIsWeb && Platform.isWindows) return 'innie#vlc';
  return 'innie#mpv';
}
