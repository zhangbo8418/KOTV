import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers.dart';
import '../remote/postmsg_host.dart';
import '../remote/remote_bridge.dart';
import '../theme/layout_scale.dart';
import '../theme/kotv_palette.dart';
import '../widgets/chrome.dart';
import 'history_screen.dart';
import 'live_screen.dart';
import 'profile_screen.dart';
import 'search_screen.dart';
import 'settings_screen.dart';
import 'collect_screen.dart';
import 'video_screen.dart';

/// 对齐 Legacy：宽屏单栈换页；竖屏窄窗用底部菜单（普通 App）。
enum KotvPage { video, search, history, live, settings, profile, collect }

final kotvPageProvider = StateProvider<KotvPage>((ref) => KotvPage.video);

final rootNavigatorKey = GlobalKey<NavigatorState>();

class AppShell extends ConsumerStatefulWidget {
  const AppShell({super.key});

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell> {
  RemoteBridge? _bridge;
  PostMsgHost? _postMsg;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _wireRemote());
  }

  void _wireRemote() {
    final api = ref.read(apiProvider);
    _bridge?.stop();
    _postMsg?.stop();
    _bridge = RemoteBridge(api)
      ..onSearch = (kw) {
        ref.read(pendingSearchProvider.notifier).state = kw;
        ref.read(kotvPageProvider.notifier).state = KotvPage.search;
      }
      ..start();
    _postMsg = PostMsgHost(api, navigatorKey: rootNavigatorKey)..start();
    ref.read(remoteBridgeProvider.notifier).state = _bridge;
    // 启动时同步无痕开关到本地历史写入逻辑
    api.getSettings().then((st) {
      final inc = '${((st['settings'] as Map?) ?? const {})['incognito'] ?? ''}'.toLowerCase() == 'true';
      return LocalHistory.setIncognito(inc);
    }).catchError((_) {});
  }

  @override
  void dispose() {
    _bridge?.stop();
    _postMsg?.stop();
    super.dispose();
  }

  int _bottomIndex(KotvPage page) {
    return switch (page) {
      KotvPage.video => 0,
      KotvPage.live => 1,
      KotvPage.search => 2,
      KotvPage.profile || KotvPage.history || KotvPage.collect || KotvPage.settings => 3,
    };
  }

  void _onBottomTap(int i) {
    final next = switch (i) {
      0 => KotvPage.video,
      1 => KotvPage.live,
      2 => KotvPage.search,
      _ => KotvPage.profile,
    };
    ref.read(kotvPageProvider.notifier).state = next;
  }

  @override
  Widget build(BuildContext context) {
    final page = ref.watch(kotvPageProvider);
    final busy = ref.watch(uiBusyProvider);
    final bottomNav = KotvLayout.useBottomNav(context);

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: AppBackdrop(
        child: ScaledLayoutBox(
          child: Stack(
            fit: StackFit.expand,
            children: [
              switch (page) {
                KotvPage.video => const VideoScreen(),
                KotvPage.search => const SearchScreen(),
                KotvPage.history => const HistoryScreen(),
                KotvPage.live => const LiveScreen(),
                KotvPage.settings => const SettingsScreen(),
                KotvPage.profile => const ProfileScreen(),
                KotvPage.collect => const CollectScreen(),
              },
              if (busy != null && busy.isNotEmpty)
                Positioned.fill(
                  child: ColoredBox(
                    color: const Color(0x990A0820),
                    child: Center(
                      child: Container(
                        constraints: BoxConstraints(
                          minWidth: KotvLayout.isCompact(context) ? 200 : 280,
                          maxWidth: 420,
                        ),
                        padding: const EdgeInsets.symmetric(horizontal: 36, vertical: 28),
                        decoration: BoxDecoration(
                          color: const Color(0xCC63248A),
                          borderRadius: BorderRadius.circular(18),
                          border: Border.all(color: const Color(0x55D8A5E8)),
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const SizedBox(
                              width: 36,
                              height: 36,
                              child: CircularProgressIndicator(color: Colors.white, strokeWidth: 3),
                            ),
                            const SizedBox(height: 14),
                            Text(
                              busy,
                              textAlign: TextAlign.center,
                              style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w600),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
      bottomNavigationBar: bottomNav
          ? Builder(builder: (context) {
              final p = KotvPalette.of(context);
              return NavigationBar(
                height: 64,
                backgroundColor: p.bottomNav,
                indicatorColor: p.selected,
                surfaceTintColor: Colors.transparent,
                selectedIndex: _bottomIndex(page),
                onDestinationSelected: _onBottomTap,
                labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
                destinations: [
                  NavigationDestination(
                    icon: Icon(Icons.home_outlined, color: p.muted),
                    selectedIcon: const Icon(Icons.home_rounded, color: Colors.white),
                    label: '首页',
                  ),
                  NavigationDestination(
                    icon: Icon(Icons.live_tv_outlined, color: p.muted),
                    selectedIcon: const Icon(Icons.live_tv, color: Colors.white),
                    label: '直播',
                  ),
                  NavigationDestination(
                    icon: Icon(Icons.search_rounded, color: p.muted),
                    selectedIcon: const Icon(Icons.search_rounded, color: Colors.white),
                    label: '搜索',
                  ),
                  NavigationDestination(
                    icon: Icon(Icons.person_outline_rounded, color: p.muted),
                    selectedIcon: const Icon(Icons.person_rounded, color: Colors.white),
                    label: '我的',
                  ),
                ],
              );
            })
          : null,
    );
  }
}

void goKotvPage(WidgetRef ref, KotvPage page) {
  ref.read(kotvPageProvider.notifier).state = page;
}

String remoteHint(WidgetRef ref) {
  final base = ref.read(engineLauncherProvider).baseUrl;
  return base.isEmpty ? 'http://127.0.0.1:9978' : base;
}
