import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../player/kotv_platform.dart';
import '../screens/file_browser_screen.dart';

const _fontTypes = XTypeGroup(
  label: '字体',
  extensions: ['ttf', 'otf', 'ttc', 'otc'],
);

/// 选择本地字体文件（Android 仓内浏览器 / SAF；桌面系统对话框）。
Future<String?> kotvPickFontFile(BuildContext context) async {
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
          title: '选择字体文件',
        );
        final raw = (picked ?? '').trim();
        if (raw.isEmpty) return null;
        return raw.startsWith('file:') ? Uri.parse(raw).toFilePath() : raw;
      }
      final path = await ch.invokeMethod<String>('pickConfigFile');
      final raw = (path ?? '').trim();
      if (raw.isEmpty) return null;
      if (raw.startsWith('file:')) return Uri.parse(raw).toFilePath();
      return raw;
    } catch (_) {}
  }
  final XFile? file = await openFile(acceptedTypeGroups: [_fontTypes]);
  if (file == null) return null;
  return file.path;
}
