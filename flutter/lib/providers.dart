import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'api/kotv_api.dart';
import 'engine/engine_launcher.dart';
import 'engine/engine_status.dart';
import 'remote/remote_bridge.dart';

final engineLauncherProvider = Provider<EngineLauncher>((ref) {
  final launcher = EngineLauncher();
  ref.onDispose(launcher.dispose);
  return launcher;
});

/// 进入应用前的引擎状态（连接、远端登录）。换地址、登录、登录失效后 invalidate 重查。
final engineStatusProvider = FutureProvider<KotvEngineStatus>(
    (ref) => kotvCheckEngine(ref.watch(engineLauncherProvider)));

final apiProvider = Provider<KotvApi>((ref) {
  final launcher = ref.watch(engineLauncherProvider);
  return launcher.client();
});

final configProvider = FutureProvider<Map<String, dynamic>>((ref) async {
  if (!(await ref.watch(engineStatusProvider.future)).ready) return const <String, dynamic>{};
  final api = ref.watch(apiProvider);
  // 有源时短等 ready；无源立刻返回。http(s) 仓库由首页进入时再请求，这里只读当前配置。
  for (var i = 0; i < 20; i++) {
    try {
      final cfg = await api.getConfig();
      if (cfg['ready'] == true) return cfg;
      final source = '${cfg['source'] ?? ''}'.trim();
      final err = '${cfg['error'] ?? ''}'.trim();
      if (err.isNotEmpty) return cfg;
      final noSource = source.isEmpty &&
          (err.isEmpty || err.contains('未配置') || err.contains('点播源') || err.contains('请输入'));
      if (noSource) return cfg;
      await Future<void>.delayed(const Duration(milliseconds: 300));
    } catch (_) {
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
  }
  try {
    return await api.getConfig();
  } catch (_) {
    return const <String, dynamic>{};
  }
});

/// 引擎设置（含 wallMode）+ backdrop 解析结果。
final settingsProvider = FutureProvider<Map<String, dynamic>>((ref) async {
  if (!(await ref.watch(engineStatusProvider.future)).ready) return const <String, dynamic>{};
  return ref.watch(apiProvider).getSettings();
});

/// settings 刷新 loading 时保留上一份 backdrop，避免壁纸层闪空。
final Map<String, dynamic> _stickyBackdrop = <String, dynamic>{};

/// 背景规格：优先 settings.backdrop（wallMode）。
final backdropProvider = Provider<Map<String, dynamic>>((ref) {
  final st = ref.watch(settingsProvider);
  return st.maybeWhen(
    data: (d) {
      final m = Map<String, dynamic>.from((d['backdrop'] as Map?) ?? const {});
      _stickyBackdrop
        ..clear()
        ..addAll(m);
      return Map<String, dynamic>.from(_stickyBackdrop);
    },
    orElse: () => Map<String, dynamic>.from(_stickyBackdrop),
  );
});

final pendingSearchProvider = StateProvider<String?>((ref) => null);

final remoteBridgeProvider = StateProvider<RemoteBridge?>((ref) => null);

/// 全局忙碌遮罩文案；非空时 shell 显示加载层（loadingHolder）。
final uiBusyProvider = StateProvider<String?>((ref) => null);

/// 点播首页内容世代：清缓存/换源后递增，驱动 [VideoScreen] 强制重拉。
final vodContentEpochProvider = StateProvider<int>((ref) => 0);

/// 点播竖屏沉浸全屏：隐藏 shell 底栏，避免原位全屏时露出「首页/直播/搜索/我的」。
final detailImmersiveFullscreenProvider = StateProvider<bool>((ref) => false);

/// 直播页内全屏：壳层取消 SafeArea，画面铺满含刘海一侧（否则「适应屏幕」两侧黑边不等宽）。
final liveImmersiveFullscreenProvider = StateProvider<bool>((ref) => false);

/// 详情/文件浏览器等压在壳上的页：藏底栏并取消顶 SafeArea，让页内壁纸盖住壳层边条。
final detailChromeCoverProvider = StateProvider<bool>((ref) => false);

int _detailChromeCoverDepth = 0;

/// 进盖壳页时调用；可嵌套（详情上再开文件浏览器）。
void kotvPushChromeCover(StateController<bool> notifier) {
  if (!notifier.state) notifier.state = true;
  _detailChromeCoverDepth++;
}

/// 离盖壳页时调用；深度归零才关掉 provider。
void kotvPopChromeCover(StateController<bool> notifier) {
  if (_detailChromeCoverDepth > 0) _detailChromeCoverDepth--;
  if (_detailChromeCoverDepth == 0 && notifier.state) {
    notifier.state = false;
  }
}

/// 盖壳页已经不在树上，但深度或标志还留着。清掉，避免设置等页顶栏一直画进状态栏。
void kotvResetChromeCover(StateController<bool> notifier) {
  _detailChromeCoverDepth = 0;
  if (notifier.state) notifier.state = false;
}

/// 详情和文件浏览共用：同一页只 push 一次，release 才 pop。
class KotvChromeCoverSession {
  bool held = false;

  void hold(StateController<bool> notifier) {
    if (held) return;
    kotvPushChromeCover(notifier);
    held = true;
  }

  /// initState/activate 里不能改 provider。等这一帧画完，页面还在栈上再盖壳。
  void holdAfterFrame(BuildContext context, bool Function() mounted, StateController<bool> Function() read) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted()) return;
      final route = ModalRoute.of(context);
      if (route != null && !route.isActive) return;
      hold(read());
    });
  }

  void release(StateController<bool> notifier) {
    if (!held) return;
    held = false;
    try {
      kotvPopChromeCover(notifier);
    } catch (_) {}
  }
}
