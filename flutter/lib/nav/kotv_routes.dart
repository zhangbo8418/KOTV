import '../util/kotv_io.dart';

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';

/// 详情页路由：移动端用 [CupertinoPageRoute] 以支持边缘侧滑返回。
Route<T> kotvDetailRoute<T>({required WidgetBuilder builder}) {
  if (!kIsWeb && (Platform.isIOS || Platform.isAndroid)) {
    return CupertinoPageRoute<T>(builder: builder);
  }
  return MaterialPageRoute<T>(builder: builder);
}
