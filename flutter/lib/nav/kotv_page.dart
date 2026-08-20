import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 宽屏单栈换页；竖屏窄窗用底部菜单（普通 App）。
enum KotvPage { video, search, history, live, settings, profile, collect }

final kotvPageProvider = StateProvider<KotvPage>((ref) => KotvPage.video);

/// 主 Tab 返回栈（不含详情 push）；用于设置/我的等返回上一页，而非直接退桌面。
final kotvPageStackProvider = StateProvider<List<KotvPage>>((ref) => <KotvPage>[]);

/// 鼠标右键：与系统返回同一套逻辑（含根栈全屏页）。由 AppShell 注册。
/// 到根页即止，不弹出「再按一次返回桌面」。
void Function()? kotvHandleAppBack;
