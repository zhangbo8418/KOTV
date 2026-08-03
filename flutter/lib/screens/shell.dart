import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers.dart';
import '../remote/postmsg_host.dart';
import '../remote/remote_bridge.dart';
import '../theme/layout_scale.dart';
import '../theme/kotv_palette.dart';
import '../widgets/chrome.dart';
import 'collect_screen.dart';
import 'detail_screen.dart';
import 'history_screen.dart';
import 'live_screen.dart';
import 'profile_screen.dart';
import 'search_screen.dart';
import 'settings_screen.dart';
import 'video_screen.dart';

/// 对齐 Legacy：宽屏单栈换页；竖屏窄窗用底部菜单（普通 App）。
enum KotvPage { video, search, history, live, settings, profile, collect }

final kotvPageProvider = StateProvider<KotvPage>((ref) => KotvPage.video);

/// 主 Tab 返回栈（不含详情 push）；用于设置/我的等返回上一页，而非直接退桌面。
final kotvPageStackProvider = StateProvider<List<KotvPage>>((ref) => <KotvPage>[]);

final rootNavigatorKey = GlobalKey<NavigatorState>();

class AppShell extends ConsumerStatefulWidget {
  const AppShell({super.key});

  @override
  ConsumerState<AppShell> createState() => _AppShellState();
}

class _AppShellState extends ConsumerState<AppShell> {
  RemoteBridge? _bridge;
  PostMsgHost? _postMsg;
  DateTime? _lastHomeBackAt;

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
        goKotvPage(ref, KotvPage.search);
        ref.read(pendingSearchProvider.notifier).state = kw;
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
    // 底栏切主 Tab：清空返回栈，避免从深层页「返回」跳到已离开的 Tab
    ref.read(kotvPageStackProvider.notifier).state = <KotvPage>[];
    goKotvPage(ref, next, recordHistory: false);
  }

  Widget _pageOf(KotvPage page) {
    return switch (page) {
      KotvPage.video => const VideoScreen(),
      KotvPage.search => const SearchScreen(),
      KotvPage.history => const HistoryScreen(),
      KotvPage.live => const LiveScreen(),
      KotvPage.settings => const SettingsScreen(),
      KotvPage.profile => const ProfileScreen(),
      KotvPage.collect => const CollectScreen(),
    };
  }

  /// 系统/手势/遥控返回：先关根 Navigator 弹窗 → 再 pop 详情 → 再退主 Tab → 首页连按两次退桌面。
  void _onShellBack() {
    final root = rootNavigatorKey.currentState;
    // 扫码等 useRootNavigator 弹窗在根栈顶：直接 pop，由弹窗 PopScope 回报 dismiss。
    if (root != null && root.canPop()) {
      root.pop();
      return;
    }
    final post = PostMsgHost.instance;
    if (post != null && post.hasOpenDialog) {
      unawaited(post.cancelAll(reply: true, popDialog: true));
      return;
    }
    final page = ref.read(kotvPageProvider);
    final nav = GlobalObjectKey<NavigatorState>(page).currentState;
    if (nav != null && nav.canPop()) {
      nav.pop();
      return;
    }
    if (page != KotvPage.video) {
      _lastHomeBackAt = null;
      kotvPageBack(ref);
      return;
    }
    // 首页：连按两次才退桌面（常见 TV/Android 习惯；避免误触直接出 App）
    final now = DateTime.now();
    final last = _lastHomeBackAt;
    if (last != null && now.difference(last) < const Duration(seconds: 2)) {
      _lastHomeBackAt = null;
      SystemNavigator.pop();
      return;
    }
    _lastHomeBackAt = now;
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger?.hideCurrentSnackBar();
    messenger?.showSnackBar(
      const SnackBar(
        content: Text('再按一次返回桌面'),
        duration: Duration(seconds: 2),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final page = ref.watch(kotvPageProvider);
    final busy = ref.watch(uiBusyProvider);
    final bottomNav = KotvLayout.useBottomNav(context);

    return PopScope(
      // 根层始终拦截：由 [_onShellBack] 决定 pop 详情 / 换页 / 退桌面
      canPop: false,
      onPopInvoked: (didPop) {
        if (didPop) return;
        _onShellBack();
      },
      child: Scaffold(
        backgroundColor: Colors.transparent,
        // Android edge-to-edge：顶栏按钮若画进状态栏区域会被系统吃掉点击
        body: SafeArea(
          bottom: false,
          child: AppBackdrop(
            child: ScaledLayoutBox(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  // 详情等子页 push 到此 Navigator，底栏保持可见。
                  // GlobalObjectKey(page)：切 Tab 重建栈，同时可从外壳 pop 详情。
                  Navigator(
                    key: GlobalObjectKey<NavigatorState>(page),
                    onGenerateRoute: (settings) {
                      return MaterialPageRoute<void>(
                        settings: settings,
                        builder: (_) => _pageOf(page),
                      );
                    },
                  ),
                  if (busy != null && busy.isNotEmpty)
                    Positioned.fill(
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onLongPress: () => ref.read(uiBusyProvider.notifier).state = null,
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
                    ),
                ],
              ),
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
      ),
    );
  }
}

void goKotvPage(WidgetRef ref, KotvPage page, {bool recordHistory = true}) {
  final cur = ref.read(kotvPageProvider);
  if (recordHistory && cur != page) {
    final stack = List<KotvPage>.from(ref.read(kotvPageStackProvider));
    stack.add(cur);
    while (stack.length > 24) {
      stack.removeAt(0);
    }
    ref.read(kotvPageStackProvider.notifier).state = stack;
  }
  // 切主页面前硬停详情播放，避免后台出声。
  unawaited(DetailScreen.prepareLeave());
  // 切 Tab 时若有声明式弹窗则关掉，避免遮罩残留挡后续详情
  if (cur != page) {
    final post = PostMsgHost.instance;
    if (post != null && post.hasOpenDialog) {
      unawaited(post.cancelAll(reply: true));
    }
  }
  ref.read(kotvPageProvider.notifier).state = page;
}

/// 顶栏/遥控返回：有历史则回上一主页，否则回首页。
void kotvPageBack(WidgetRef ref) {
  final stack = List<KotvPage>.from(ref.read(kotvPageStackProvider));
  if (stack.isNotEmpty) {
    final prev = stack.removeLast();
    ref.read(kotvPageStackProvider.notifier).state = stack;
    goKotvPage(ref, prev, recordHistory: false);
    return;
  }
  goKotvPage(ref, KotvPage.video, recordHistory: false);
}

String remoteHint(WidgetRef ref) {
  final base = ref.read(engineLauncherProvider).baseUrl;
  return base.isEmpty ? 'http://127.0.0.1:9978' : base;
}
