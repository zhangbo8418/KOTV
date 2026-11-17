import 'dart:async';

/// 焦点停留短延迟后触发；失焦取消，避免快速划过连打。
///
/// 首页分类、直播分组、点播线路/分集区间共用。
class KotvFocusArm {
  KotvFocusArm({this.delay = const Duration(milliseconds: 100)});

  final Duration delay;
  Timer? _arm;
  Object? _pending;

  void dispose() {
    _arm?.cancel();
    _arm = null;
    _pending = null;
  }

  /// [token] 标识当前武装目标；失焦且仍是同一 token 时取消。
  void onFocusChange(Object token, bool focused, void Function() fire) {
    if (focused) {
      _arm?.cancel();
      _pending = token;
      _arm = Timer(delay, () {
        if (_pending != token) return;
        fire();
      });
      return;
    }
    if (_pending == token) {
      _arm?.cancel();
      _pending = null;
    }
  }
}
