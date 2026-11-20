import '../util/kotv_io.dart';
import 'kotv_web_os_stub.dart' if (dart.library.html) 'kotv_web_os_html.dart';

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

/// 浏览器所在系统。原生客户端为空，平台用 kotvHostPlatform。
String kotvHostOs() => kIsWeb ? kotvWebOperatingSystem() : '';

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
bool kotvIsWindows() => !kIsWeb && Platform.isWindows;
bool kotvIsMacOS() => !kIsWeb && Platform.isMacOS;
bool kotvIsLinux() => !kIsWeb && Platform.isLinux;

/// 原生 libmpv 通道（`kotv_mpv`）。
///
/// Android Surface；macOS ASBDL underlay；Windows 子 HWND（Win8+ DComp 下 Flutter 在上）；
/// Linux X11 wid（非 X11 暂无画面）。iOS 走 media_kit。
bool kotvUsesNativeMpv() =>
    kotvIsAndroid() || kotvIsMacOS() || kotvIsWindows() || kotvIsLinux();

/// Win8+：DComp 补丁引擎把 Flutter 合成在 child HWND 视频之上（洞 clear）。
/// Win7：无 DComp，走 [kotvUsesWindowsNativeChrome]。
bool kotvUsesWindowsDcompUnderlay() => kotvIsWindows() && !kotvIsWindows7();

/// Win7：WPF 透明遮罩播控/选集/直播菜单（库存引擎 + mpv 子 HWND；与 Win8+ DComp 隔离）。
bool kotvUsesWindowsNativeChrome() => kotvIsWindows7();

/// 设为 true 时 macOS 发行包不链 FVP/mdk（仅原生 MPV）；默认 false，MPV+FVP 全功能。
const bool kotvMacosNoFvp = bool.fromEnvironment('KOTV_MACOS_NO_FVP', defaultValue: false);

/// Surface=0（默认 HDR），Texture=1。
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

/// Surface/Texture：Android 内置 Exo / MPV（设置项 `playerRender`）。
/// macOS 原生层固定 AVSampleBufferDisplayLayer。
bool kotvPlayerRenderApplies(String playerVal) {
  if (!kotvIsAndroid()) return false;
  final b = kotvEmbedBackend(playerVal);
  return b == KotvEmbedBackend.exo || b == KotvEmbedBackend.mpv;
}

/// 点播默认：Web 与 iOS 用平台播放器（iOS 为 AVPlayer）；Android=Exo；桌面=MPV。
String kotvDefaultVodPlayer() {
  if (kIsWeb || kotvIsIOS()) return 'innie#html';
  if (kotvIsAndroid()) return 'innie#exo';
  return 'innie#mpv';
}

/// 直播默认与点播相同。
String kotvDefaultLivePlayer() => kotvDefaultVodPlayer();

/// `innie#html` 的显示名。iOS 上是 AVPlayer，其它平台是浏览器 HTML5。
String kotvHtmlPlayerLabel() => kotvIsIOS() ? 'AVPlayer' : '浏览器 HTML5';

String kotvClampPlayerVal(String raw, {required bool live}) {
  final v = raw.trim();
  // 点播/直播选项表相同，默认值仍按 live 区分。
  for (final o in kotvPlayerOptions()) {
    if (o.$2 == v) return v;
  }
  return live ? kotvDefaultLivePlayer() : kotvDefaultVodPlayer();
}

bool kotvCanSwitchPlayer({required bool live}) => kotvPlayerOptions().length > 1;

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

/// 点播/直播共用同一套内置与外部播放器选项（平台差异在默认值，不在列表）。
List<(String, String)> kotvPlayerOptions() {
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
      ('外部播放器', 'outie#view'),
    ];
  }
  if (kotvIsIOS()) {
    return [
      ('${kotvHtmlPlayerLabel()}（默认）', 'innie#html'),
      ('内置 MPV', 'innie#mpv'),
      ('内置 FVP', 'innie#fvp'),
    ];
  }
  return [
    ('内置 MPV（默认）', 'innie#mpv'),
    // KOTV_MACOS_NO_FVP=1 打的 macOS 包不带 FVP。
    if (!(Platform.isMacOS && kotvMacosNoFvp)) ('内置 FVP', 'innie#fvp'),
    // 一项「外部播放器」；桌面由宿主列出本机视频应用供选择。
    ('外部播放器', 'outie#view'),
  ];
}

/// 点播/直播共用 [kotvPlayerOptions]；保留别名方便调用处语义区分。
List<(String, String)> kotvVodPlayerOptions() => kotvPlayerOptions();

List<(String, String)> kotvLivePlayerOptions() => kotvPlayerOptions();

/// 引擎 Available() 里的键。内置项带 embed_ 前缀，不看本机是否装了外部程序。
String kotvPlayerAvailKey(String playerVal) {
  final v = playerVal.trim();
  final i = v.indexOf('#');
  if (i <= 0 || i >= v.length - 1) return '';
  final mode = v.substring(0, i);
  final name = v.substring(i + 1);
  if (mode == 'innie') return 'embed_$name';
  if (mode == 'outie') return name;
  return '';
}

bool kotvPlayerAlwaysListed(String availKey) => availKey.startsWith('embed_');

bool kotvIsExternalPlayer(String playerVal) => playerVal.trim().startsWith('outie#');

/// 内置项始终保留。外部项只有 [available] 里对应键为真才保留。
List<(String, String)> kotvVisiblePlayerOptions(
  List<(String, String)> options,
  Map<String, dynamic> available,
) {
  return [
    for (final o in options)
      if (kotvPlayerAlwaysListed(kotvPlayerAvailKey(o.$2)) || available[kotvPlayerAvailKey(o.$2)] == true) o,
  ];
}
