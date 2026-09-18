import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../player/kotv_platform.dart';
import '../screens/file_browser_screen.dart';

const _subtitleTypes = XTypeGroup(
  label: '字幕',
  extensions: ['srt', 'ass', 'ssa', 'vtt', 'sub', 'idx', 'sup', 'txt'],
);

/// 选择本地字幕文件：Android 复用仓内文件浏览器 / SAF；桌面走系统对话框。
Future<String?> kotvPickSubtitleFile(BuildContext context) async {
  if (kIsWeb) return null;
  if (kotvIsAndroid()) {
    try {
      const ch = MethodChannel('kotv_android');
      try {
        await ch.invokeMethod<bool>('ensureStoragePermission');
      } catch (_) {}
      var useBrowser = false;
      try {
        useBrowser = await ch.invokeMethod<bool>('useFileBrowser') ?? false;
      } catch (_) {}
      if (useBrowser && context.mounted) {
        final root = ((await ch.invokeMethod<String>('storageRoot')) ?? '').trim();
        final picked = await FileBrowserScreen.pick(
          context,
          root: root.isEmpty ? '/storage/emulated/0' : root,
          title: '选择字幕文件',
        );
        final raw = (picked ?? '').trim();
        if (raw.isEmpty) return null;
        return raw.startsWith('file:') ? raw : raw;
      }
      final path = await ch.invokeMethod<String>('pickConfigFile');
      final raw = (path ?? '').trim();
      if (raw.isEmpty) return null;
      if (raw.startsWith('file:')) {
        return Uri.parse(raw).toFilePath();
      }
      return raw;
    } catch (_) {}
  }
  final XFile? file = await openFile(acceptedTypeGroups: [_subtitleTypes]);
  if (file == null) return null;
  return file.path;
}
