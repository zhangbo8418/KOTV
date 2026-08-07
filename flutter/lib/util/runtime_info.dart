import 'kotv_io.dart';

import 'package:flutter/foundation.dart';

/// 桌面端完整运行时键；安卓只展示引擎/bridge 相关（无捆绑 chromium/ffmpeg/vlc 等）。
const kotvRuntimeDisplayKeysDesktop = <String>[
  'platform',
  'java',
  'python',
  'quickjs',
  'bridge',
  'chromium',
  'ffmpeg',
  'libvlc',
  'mpv',
  'vlc',
];

const kotvRuntimeDisplayKeysAndroid = <String>[
  'platform',
  'java',
  'python',
  'quickjs',
  'bridge',
];

List<String> kotvRuntimeDisplayKeysForPlatform() {
  if (!kIsWeb && Platform.isAndroid) return kotvRuntimeDisplayKeysAndroid;
  return kotvRuntimeDisplayKeysDesktop;
}

/// 按固定顺序输出 `key: value` 行；未知键忽略。
List<String> formatKotvRuntimeLines(
  Map<String, String> runtime, {
  bool includeMissingKeys = true,
}) {
  final keys = kotvRuntimeDisplayKeysForPlatform();
  final out = <String>[];
  for (final k in keys) {
    final v = runtime[k]?.trim();
    if (v != null && v.isNotEmpty) {
      // 安卓不展示桌面播放器类 missing
      if (!kIsWeb && Platform.isAndroid && v == '(missing)') continue;
      out.add('$k: $v');
    } else if (includeMissingKeys && (k == 'mpv' || k == 'vlc') && (kIsWeb || !Platform.isAndroid)) {
      out.add('$k: (missing)');
    }
  }
  return out;
}
