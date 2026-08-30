import 'kotv_io.dart';

import 'package:flutter/foundation.dart';

/// 桌面客户端：页内 MPV 看 libmpv；外部 mpv 可执行文件另列。
const kotvRuntimeDisplayKeysDesktop = <String>[
  'platform',
  'java',
  'python',
  'quickjs',
  'bridge',
  'chromium',
  'ffmpeg',
  'libmpv',
  'mpv',
];

/// 安卓客户端：只展示引擎/bridge；不展示桌面播放器库。
const kotvRuntimeDisplayKeysAndroid = <String>[
  'platform',
  'java',
  'python',
  'quickjs',
  'bridge',
];

/// Web 客户端：浏览器内不能加载 libmpv，列表也不展示播放器库。
const kotvRuntimeDisplayKeysWeb = <String>[
  'platform',
  'java',
  'python',
  'quickjs',
  'bridge',
];

List<String> kotvRuntimeDisplayKeysForPlatform() {
  if (kIsWeb) return kotvRuntimeDisplayKeysWeb;
  if (Platform.isAndroid) return kotvRuntimeDisplayKeysAndroid;
  return kotvRuntimeDisplayKeysDesktop;
}

/// 按固定顺序输出 `key: value` 行；未知键忽略。
List<String> formatKotvRuntimeLines(
  Map<String, String> runtime, {
  bool includeMissingKeys = true,
}) {
  final keys = kotvRuntimeDisplayKeysForPlatform();
  final out = <String>[];
  final hideMissingPlayerLibs = kIsWeb || (!kIsWeb && Platform.isAndroid);
  for (final k in keys) {
    final v = runtime[k]?.trim();
    if (v != null && v.isNotEmpty) {
      if (hideMissingPlayerLibs && v == '(missing)') continue;
      // 页内播放用捆绑 libmpv；外部 mpv.exe 未安装时不必占一行。
      if (k == 'mpv' && v == '(missing)') continue;
      out.add('$k: $v');
    } else if (includeMissingKeys && !kIsWeb && !Platform.isAndroid && k == 'libmpv') {
      out.add('libmpv: (missing)');
    }
  }
  return out;
}
