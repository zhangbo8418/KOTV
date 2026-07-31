import 'dart:io';

import 'package:flutter/foundation.dart';

/// Win7 实验线：media_kit/libmpv 在部分机型上会在创建 Player / 开播时卡死 UI。
bool kotvIsWindows7() {
  if (kIsWeb || !Platform.isWindows) return false;
  final v = Platform.operatingSystemVersion.toLowerCase();
  if (v.contains('windows 7') || v.contains('win7')) return true;
  // 兼容仅返回内部版本号的环境（6.1 = Win7）。
  return RegExp(r'(^|[^\d])6\.1([^\d]|$)').hasMatch(v);
}
