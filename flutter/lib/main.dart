import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';

import 'desktop/mini_player_window.dart';
import 'engine/engine_launcher.dart';
import 'providers.dart';
import 'screens/shell.dart';
import 'theme/layout_scale.dart';
import 'theme/kotv_palette.dart';
import 'theme/kotv_theme.dart';
import 'widgets/chrome.dart';
import 'widgets/h_scroll.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  final prefs = await SharedPreferences.getInstance();
  if (!kIsWeb && (Platform.isMacOS || Platform.isWindows || Platform.isLinux)) {
    await windowManager.ensureInitialized();
    final savedW = prefs.getDouble('window_w');
    final savedH = prefs.getDouble('window_h');
    final savedX = prefs.getDouble('window_x');
    final savedY = prefs.getDouble('window_y');
    final size = Size(
      (savedW ?? 1280).clamp(kotvMinWindowSize.width, 10000),
      (savedH ?? 720).clamp(kotvMinWindowSize.height, 10000),
    );
    final opts = WindowOptions(
      size: size,
      // 允许缩到接近手机竖/横屏，由布局断点自动切底栏/顶栏
      minimumSize: kotvMinWindowSize,
      center: savedX == null || savedY == null,
      title: 'KO影视',
    );
    await windowManager.waitUntilReadyToShow(opts, () async {
      if (savedX != null && savedY != null) {
        try {
          await windowManager.setPosition(Offset(savedX, savedY));
        } catch (_) {}
      }
      await windowManager.show();
      await windowManager.focus();
    });
  }
  final engineUrl = prefs.getString('engine_base_url');
  runApp(ProviderScope(
    overrides: [
      engineLauncherProvider.overrideWith((ref) {
        final launcher = EngineLauncher();
        if (engineUrl != null && engineUrl.isNotEmpty) {
          launcher.baseUrl = engineUrl;
        }
        ref.onDispose(launcher.dispose);
        return launcher;
      }),
    ],
    child: const KotvApp(),
  ));
}

class KotvApp extends ConsumerStatefulWidget {
  const KotvApp({super.key});

  @override
  ConsumerState<KotvApp> createState() => _KotvAppState();
}

class _KotvAppState extends ConsumerState<KotvApp> with WindowListener, WidgetsBindingObserver {
  Future<void> _setupBackendUrl() async {
    final launcher = ref.read(engineLauncherProvider);
    final ctrl = TextEditingController(
      text: launcher.baseUrl == 'http://127.0.0.1:9978' ? '' : launcher.baseUrl,
    );
    final p = KotvPalette.of(context);
    final v = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: p.dialogBg,
        title: Text('连接后端服务', style: TextStyle(color: p.fg, fontWeight: FontWeight.w700)),
        content: SizedBox(
          width: 520,
          child: TextField(
            controller: ctrl,
            autofocus: true,
            style: TextStyle(color: p.fg),
            decoration: InputDecoration(
              hintText: '例如：http://10.0.0.8:9978 或 https://api.example.com',
              hintStyle: TextStyle(color: p.muted),
            ),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text('取消', style: TextStyle(color: p.muted))),
          FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text.trim()), child: const Text('保存并重试')),
        ],
      ),
    );
    if (v == null || v.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('engine_base_url', v);
    launcher.baseUrl = v;
    ref.invalidate(engineReadyProvider);
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // 同步一次当前系统亮暗
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(platformBrightnessProvider.notifier).state =
          WidgetsBinding.instance.platformDispatcher.platformBrightness;
    });
    if (!kIsWeb && (Platform.isMacOS || Platform.isWindows || Platform.isLinux)) {
      windowManager.addListener(this);
      windowManager.setPreventClose(true);
    }
  }

  @override
  void dispose() {
    _saveBoundsTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    if (!kIsWeb && (Platform.isMacOS || Platform.isWindows || Platform.isLinux)) {
      windowManager.removeListener(this);
    }
    super.dispose();
  }

  @override
  void didChangePlatformBrightness() {
    final b = WidgetsBinding.instance.platformDispatcher.platformBrightness;
    ref.read(platformBrightnessProvider.notifier).state = b;
  }

  Timer? _saveBoundsTimer;

  Future<void> _persistWindowBounds() async {
    if (kIsWeb || !(Platform.isMacOS || Platform.isWindows || Platform.isLinux)) return;
    if (MiniPlayerWindow.active) return;
    try {
      final size = await windowManager.getSize();
      final pos = await windowManager.getPosition();
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble('window_w', size.width);
      await prefs.setDouble('window_h', size.height);
      await prefs.setDouble('window_x', pos.dx);
      await prefs.setDouble('window_y', pos.dy);
    } catch (_) {}
  }

  void _scheduleSaveWindowBounds() {
    _saveBoundsTimer?.cancel();
    _saveBoundsTimer = Timer(const Duration(milliseconds: 400), () {
      unawaited(_persistWindowBounds());
    });
  }

  @override
  void onWindowResize() => _scheduleSaveWindowBounds();

  @override
  void onWindowMove() => _scheduleSaveWindowBounds();

  @override
  void onWindowClose() async {
    _saveBoundsTimer?.cancel();
    await _persistWindowBounds();
    // 先优雅停引擎（HTTP shutdown → 杀 Java/Python）；超时再杀进程树。
    // Windows 仍避免 window_manager.destroy（Win7 易 WER），最后 exit。
    try {
      await ref
          .read(engineLauncherProvider)
          .shutdown()
          .timeout(const Duration(seconds: 5));
    } catch (_) {
      try {
        ref.read(engineLauncherProvider).shutdownSync();
      } catch (_) {}
    }
    if (Platform.isWindows) {
      exit(0);
    }
    try {
      await windowManager.setPreventClose(false);
    } catch (_) {}
    try {
      await windowManager.destroy();
    } catch (_) {
      exit(0);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ready = ref.watch(engineReadyProvider);
    final palette = ref.watch(kotvPaletteProvider);
    return MaterialApp(
      title: 'KO影视',
      debugShowCheckedModeBanner: false,
      navigatorKey: rootNavigatorKey,
      theme: buildKotvTheme(palette),
      // 桌面端默认不把鼠标当拖动设备；芯片/分类栏过长时需可拖拽横滚
      scrollBehavior: const KotvScrollBehavior(),
      // 色板已按 effectiveLight 生成，固定用当前 theme 即可
      themeMode: ThemeMode.light,
      home: ready.when(
        data: (ok) {
          if (!ok) {
            return AppBackdrop(
              child: Scaffold(
                backgroundColor: Colors.transparent,
                body: Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text('KO影视', style: TextStyle(fontSize: 32, fontWeight: FontWeight.w700)),
                        const SizedBox(height: 12),
                        Text(
                          Platform.isIOS
                              ? '请先连接可用后端服务'
                              : '无法连接 Go 引擎\n请先启动引擎或检查设置中的引擎地址',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Theme.of(context).colorScheme.onSurface.withOpacity(0.7)),
                        ),
                        const SizedBox(height: 16),
                        if (Platform.isIOS)
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              AppPill(label: '连接后端', width: 130, autofocus: true, onTap: _setupBackendUrl),
                              const SizedBox(width: 10),
                              AppPill(label: '重试', width: 90, onTap: () => ref.invalidate(engineReadyProvider)),
                            ],
                          )
                        else
                          AppPill(
                            label: '重试',
                            width: 120,
                            autofocus: true,
                            onTap: () => ref.invalidate(engineReadyProvider),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          }
          return const AppShell();
        },
        loading: () => const AppBackdrop(
          child: Scaffold(
            backgroundColor: Colors.transparent,
            body: Center(child: CircularProgressIndicator(color: Colors.white)),
          ),
        ),
        error: (e, _) => AppBackdrop(
          child: Scaffold(
            backgroundColor: Colors.transparent,
            body: Center(child: Text('$e', style: const TextStyle(color: Colors.white))),
          ),
        ),
      ),
    );
  }
}
