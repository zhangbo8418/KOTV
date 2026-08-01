/// 运行时信息展示顺序：两端 UI 共用；不含 jvm；mpv/vlc 置底。
const kotvRuntimeDisplayKeys = <String>[
  'platform',
  'java',
  'python',
  'chromium',
  'ffmpeg',
  'libvlc',
  'bridge',
  'quickjs',
  'mpv',
  'vlc',
];

/// 按固定顺序输出 `key: value` 行；未知键忽略，缺失键若 [includeMissingKeys] 则补 `(missing)`。
List<String> formatKotvRuntimeLines(
  Map<String, String> runtime, {
  bool includeMissingKeys = true,
}) {
  final out = <String>[];
  for (final k in kotvRuntimeDisplayKeys) {
    final v = runtime[k]?.trim();
    if (v != null && v.isNotEmpty) {
      out.add('$k: $v');
    } else if (includeMissingKeys && (k == 'mpv' || k == 'vlc')) {
      out.add('$k: (missing)');
    }
  }
  return out;
}
