import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

const _androidChannel = MethodChannel('kotv_android');

/// 清理 Android Exo SimpleCache（cacheDir/exo）。其它平台 no-op。
Future<void> kotvClearExoDiskCache() async {
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
  try {
    await _androidChannel.invokeMethod<void>('clearExoCache');
  } catch (_) {}
}
