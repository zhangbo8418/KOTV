import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/kotv_api.dart';
import '../api/kotv_auth_token.dart';
import '../providers.dart';
import '../theme/kotv_palette.dart';

/// Web：打开页登录本站账号（固定同源后端）。PC/安卓请走设置「远端登录」。
Future<bool> ensureRemoteAuthIfNeeded(BuildContext context, WidgetRef ref) async {
  final api = ref.read(apiProvider);
  Map<String, dynamic> st;
  try {
    st = await api.authStatus();
  } catch (_) {
    return true;
  }
  if (st['authRequired'] != true) return true;

  final tok = await kotvAuthToken();
  if (tok.isNotEmpty) {
    try {
      await api.authMe();
      return true;
    } catch (_) {
      await kotvClearAuthToken();
    }
  }

  if (!context.mounted) return false;
  return showRemoteLoginDialog(
    context,
    ref,
    allowRegister: st['allowRegister'] == true,
    title: kIsWeb ? '登录' : '远端登录',
    subtitle: kIsWeb ? '使用本站账号登录后即可观看' : '连接此引擎需登录一次，之后与本机使用相同',
  );
}

Future<bool> showRemoteLoginDialog(
  BuildContext context,
  WidgetRef ref, {
  bool allowRegister = false,
  String title = '远端登录',
  String? subtitle,
}) async {
  final api = ref.read(apiProvider);
  final p = KotvPalette.of(context);
  final userCtrl = TextEditingController();
  final passCtrl = TextEditingController();
  var modeRegister = false;
  final hint = subtitle ??
      (kIsWeb ? '使用本站账号登录后即可观看' : '连接此引擎需登录一次，之后与本机使用相同');

  final ok = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setLocal) => Dialog(
        backgroundColor: p.dialogBg,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(title, style: TextStyle(color: p.fg, fontWeight: FontWeight.w700, fontSize: 18)),
                const SizedBox(height: 8),
                Text(
                  modeRegister ? '创建账号后将自动登录' : hint,
                  style: TextStyle(color: p.muted, fontSize: 13),
                ),
                const SizedBox(height: 14),
                TextField(
                  controller: userCtrl,
                  autofocus: true,
                  style: TextStyle(color: p.fg),
                  decoration: InputDecoration(
                    hintText: '用户名',
                    hintStyle: TextStyle(color: p.muted),
                    filled: true,
                    fillColor: p.input,
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: passCtrl,
                  obscureText: true,
                  onSubmitted: (_) => Navigator.pop(ctx, true),
                  style: TextStyle(color: p.fg),
                  decoration: InputDecoration(
                    hintText: '密码',
                    hintStyle: TextStyle(color: p.muted),
                    filled: true,
                    fillColor: p.input,
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(10), borderSide: BorderSide.none),
                  ),
                ),
                if (allowRegister) ...[
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton(
                      onPressed: () => setLocal(() => modeRegister = !modeRegister),
                      child: Text(modeRegister ? '已有账号？去登录' : '没有账号？注册', style: TextStyle(color: p.primary)),
                    ),
                  ),
                ],
                const SizedBox(height: 8),
                FilledButton(
                  onPressed: () => Navigator.pop(ctx, true),
                  child: Text(modeRegister ? '注册并登录' : '登录'),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
  if (ok != true) return false;
  final u = userCtrl.text.trim();
  final pw = passCtrl.text;
  if (u.isEmpty || pw.isEmpty) return false;
  try {
    if (modeRegister) {
      await api.register(u, pw);
    }
    await api.login(u, pw);
    ref.invalidate(configProvider);
    ref.invalidate(homeProvider);
    ref.invalidate(settingsProvider);
    return true;
  } catch (e) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
    return false;
  }
}

/// API 抛出「需要登录」时弹出登录并返回是否成功。
Future<bool> handleAuthRequiredError(BuildContext context, WidgetRef ref, Object error) async {
  final s = '$error';
  if (!s.contains('需要登录') && !s.contains('登录已失效') && !s.contains('401')) {
    return false;
  }
  var allowReg = false;
  try {
    final st = await ref.read(apiProvider).authStatus();
    allowReg = st['allowRegister'] == true;
  } catch (_) {}
  if (!context.mounted) return false;
  return showRemoteLoginDialog(context, ref, allowRegister: allowReg);
}
