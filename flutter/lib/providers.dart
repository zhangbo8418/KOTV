import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'api/kotv_api.dart';
import 'engine/engine_launcher.dart';
import 'remote/remote_bridge.dart';

final engineLauncherProvider = Provider<EngineLauncher>((ref) {
  final launcher = EngineLauncher();
  ref.onDispose(launcher.dispose);
  return launcher;
});

final engineReadyProvider = FutureProvider<bool>((ref) async {
  final launcher = ref.watch(engineLauncherProvider);
  return launcher.ensureReady();
});

final apiProvider = Provider<KotvApi>((ref) {
  final launcher = ref.watch(engineLauncherProvider);
  return launcher.client();
});

final configProvider = FutureProvider<Map<String, dynamic>>((ref) async {
  await ref.watch(engineReadyProvider.future);
  final api = ref.watch(apiProvider);
  // 配置可能晚于 health 就绪；最多等几秒拿到 wallpaper。
  for (var i = 0; i < 15; i++) {
    final cfg = await api.getConfig();
    if (cfg['ready'] == true) return cfg;
    await Future<void>.delayed(const Duration(milliseconds: 400));
  }
  return api.getConfig();
});

/// 引擎设置（含 wallMode）+ backdrop 解析结果。
final settingsProvider = FutureProvider<Map<String, dynamic>>((ref) async {
  await ref.watch(engineReadyProvider.future);
  return ref.watch(apiProvider).getSettings();
});

/// 背景规格：优先 settings.backdrop（对齐 Legacy wallMode）。
final backdropProvider = Provider<Map<String, dynamic>>((ref) {
  final st = ref.watch(settingsProvider);
  return st.maybeWhen(
    data: (d) => Map<String, dynamic>.from((d['backdrop'] as Map?) ?? const {}),
    orElse: () => const <String, dynamic>{},
  );
});

final homeProvider = FutureProvider<Map<String, dynamic>>((ref) async {
  await ref.watch(engineReadyProvider.future);
  return ref.watch(apiProvider).home();
});

final categoryTidProvider = StateProvider<String>((ref) => 'home');

final categoryProvider = FutureProvider<Map<String, dynamic>>((ref) async {
  await ref.watch(engineReadyProvider.future);
  final tid = ref.watch(categoryTidProvider);
  return ref.watch(apiProvider).category(tid);
});

final pendingSearchProvider = StateProvider<String?>((ref) => null);

final remoteBridgeProvider = StateProvider<RemoteBridge?>((ref) => null);

/// 全局忙碌遮罩文案；非空时 shell 显示加载层（对齐 Legacy loadingHolder）。
final uiBusyProvider = StateProvider<String?>((ref) => null);
