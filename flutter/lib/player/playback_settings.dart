/// 跨 Exo / MPV / FVP 共用的播放设置键读取。
/// 键名历史为 exo*（设置白名单与落盘已固定），各引擎均读同一键。
int kotvDolbyVisionFromSettings(Map<String, dynamic> settings) {
  return int.tryParse('${settings['exoDolbyVision'] ?? '0'}') ?? 0;
}

String kotvPreferredTextLangsFromSettings(Map<String, dynamic> settings) {
  return '${settings['exoPreferredTextLangs'] ?? ''}'.trim();
}
