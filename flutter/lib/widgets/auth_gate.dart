import 'package:flutter/foundation.dart' show defaultTargetPlatform, kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/kotv_api.dart';
import '../api/kotv_auth_token.dart';
import '../api/kotv_client_store.dart';
import '../api/kotv_engine_url.dart';
import '../api/kotv_settings_cache.dart';
import '../providers.dart';
import '../theme/kotv_palette.dart';
import '../theme/layout_scale.dart';
import '../util/kotv_image_cache.dart';
import 'chrome.dart';
import 'kotv_tv_text_field.dart';

bool kotvMessageNeedsLogin(Object error) {
  final s = '$error';
  return s.contains('需要登录') ||
      s.contains('登录已失效') ||
      s.contains('HTTP 401') ||
      RegExp(r'\b401\b').hasMatch(s);
}

/// 弹出登录框（远端后端或 Web）。登录成功后重查引擎状态并返回 true。
Future<bool> kotvShowSignIn(
  BuildContext context,
  WidgetRef ref, {
  bool allowCancel = true,
  bool? allowRegister,
}) async {
  var register = allowRegister;
  if (register == null) {
    try {
      register = (await ref.read(apiProvider).authStatus())['allowRegister'] == true;
    } catch (_) {
      register = false;
    }
  }
  if (!context.mounted) return false;
  final ok = await showRemoteLoginDialog(
    context,
    ref,
    allowRegister: register,
    allowCancel: allowCancel,
  );
  if (ok) {
    KotvSettingsCache.clear();
    ref.invalidate(settingsProvider);
    ref.invalidate(engineStatusProvider);
  }
  return ok;
}

Future<bool>? _signInPending;

/// 使用中登录失效：弹登录框，成功返回 true 由调用方重试。
/// 取消则回到登录页，未登录不能继续使用。同时多处触发只弹一次。
Future<bool> kotvPresentLoginIfNeeded(BuildContext context, WidgetRef ref) {
  return _signInPending ??= () async {
    try {
      await kotvClearAuthToken();
      if (!context.mounted) return false;
      // Web：会话失效必须重新登录，取消则退回登录页（不可继续用）。
      final ok = await kotvShowSignIn(context, ref, allowCancel: !kIsWeb);
      if (!ok) ref.invalidate(engineStatusProvider);
      return ok;
    } finally {
      _signInPending = null;
    }
  }();
}

/// 已保存的远端地址。本机地址不算。
Future<String> kotvSavedRemoteEngineAddress(WidgetRef ref) async {
  final live = ref.read(engineLauncherProvider).baseUrl.trim();
  if (live.isNotEmpty && !kotvIsLocalEngineBaseUrl(live)) return live;
  final data = await KotvClientStore.load();
  for (final raw in [data.engineBaseUrl, data.engineBaseUrlDraft]) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty || kotvIsLocalEngineBaseUrl(trimmed)) continue;
    final effective = kotvEffectiveEngineBaseUrl(trimmed);
    if (!kotvIsLocalEngineBaseUrl(effective)) return effective;
  }
  return '';
}

Future<void> kotvUseLocalEngine(WidgetRef ref) async {
  // 仍指向远端时先 leave，避免只清本地 token 后靠 Presence ~90s 才释放租户态。
  final launcher = ref.read(engineLauncherProvider);
  final remote = launcher.baseUrl.trim();
  if (remote.isNotEmpty && !kotvIsLocalEngineBaseUrl(remote)) {
    try {
      await KotvApi(baseUrl: remote).sessionLeave();
    } catch (_) {}
  }
  await KotvClientStore.clearEngine();
  await kotvClearAuthToken();
  launcher.applyBaseUrl('');
  ref.invalidate(engineStatusProvider);
}

/// 保存用户填写的后端地址并重新检查，远端会进入登录。
/// 用户亲自确认了这个地址：忘掉它记住的后端身份，并清掉旧登录令牌（可能属于别的后端），
/// 重新登录后再记住新的。
Future<void> kotvFinishEngineAddress(WidgetRef ref, String url) async {
  await kotvClearAuthToken();
  await KotvClientStore.setEngineBaseUrl(url);
  await KotvClientStore.forgetEngineKey(url);
  ref.read(engineLauncherProvider).applyBaseUrl(url);
  KotvSettingsCache.clear();
  await kotvClearImageMemory();
  ref.invalidate(engineStatusProvider);
}

/// 填写或改正后端地址。探测失败时弹窗说明，输入框保持打开。
/// 取消返回 null。非 iOS 清空地址时返回空串，表示改回本机。
Future<String?> kotvPromptEngineAddress(
  BuildContext context, {
  String initial = '',
  String errorText = '',
}) async {
  final p = KotvPalette.of(context);
  final ctrl = TextEditingController(text: initial);
  final ios = !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;
  var busy = false;
  final result = await showDialog<String>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setLocal) {
        Future<void> submit() async {
          if (busy) return;
          final raw = ctrl.text.trim();
          final stored = kotvStoreEngineBaseUrl(raw);
          if (stored.isEmpty) {
            if (ios) {
              showAppNews(ctx, raw.isEmpty ? '请填写后端地址' : '没有本机引擎，请填写远端地址');
              return;
            }
            if (ctx.mounted) Navigator.pop(ctx, '');
            return;
          }
          setLocal(() => busy = true);
          try {
            await KotvApi(baseUrl: stored).verifyEngine(checkIdentity: false);
          } catch (e) {
            if (ctx.mounted) {
              setLocal(() => busy = false);
              showAppNews(ctx, '无法连接\n$stored\n$e');
            }
            return;
          }
          if (ctx.mounted) Navigator.pop(ctx, stored);
        }

        return AlertDialog(
          backgroundColor: p.dialogBg,
          title: Text(
            errorText.isEmpty ? '连接后端服务' : '无法连接',
            style: TextStyle(color: p.fg, fontWeight: FontWeight.w700),
          ),
          content: SizedBox(
            width: LayoutScale.dp(ctx, 520),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (errorText.isNotEmpty) ...[
                  Text(errorText, style: TextStyle(color: p.muted)),
                  const SizedBox(height: 12),
                ],
                KotvTvTextField(
                  controller: ctrl,
                  autofocus: true,
                  style: TextStyle(color: p.fg),
                  decoration: InputDecoration(
                    hintText: 'http://10.0.0.8:9978 或 https://api.example.com',
                    hintStyle: TextStyle(color: p.muted),
                  ),
                  onSubmitted: (_) => submit(),
                ),
              ],
            ),
          ),
          actions: [
            KotvFocusAction(label: '取消', color: p.muted, onPressed: () => Navigator.pop(ctx)),
            KotvFocusAction(label: '保存并重试', filled: true, onPressed: submit),
          ],
        );
      },
    ),
  );
  return result;
}

/// 登录框。账号预填上次登录的用户名；账号密码加密发送，成功后本设备记住登录态。
Future<bool> showRemoteLoginDialog(
  BuildContext context,
  WidgetRef ref, {
  bool allowRegister = false,
  bool allowCancel = true,
}) async {
  final client = ref.read(apiProvider);
  final p = KotvPalette.of(context);
  final userCtrl = TextEditingController(text: await KotvClientStore.remoteUsername());
  final passCtrl = TextEditingController();
  var modeRegister = false;
  final title = kIsWeb ? '登录' : '远端登录';
  final hint = kIsWeb ? '使用本站账号登录后即可观看' : '登录 ${client.baseUrl}\n之后本设备免登录，账号或地址失效时再登录';
  if (!context.mounted) return false;

  var busy = false;
  final ok = await showDialog<bool>(
    context: context,
    barrierDismissible: allowCancel,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setLocal) {
        Future<void> submit() async {
          if (busy) return;
          final u = userCtrl.text.trim();
          final pw = passCtrl.text;
          if (u.isEmpty || pw.isEmpty) {
            showAppNews(ctx, '请填写用户名和密码');
            return;
          }
          setLocal(() => busy = true);
          try {
            if (modeRegister) {
              await client.register(u, pw);
            }
            await client.login(u, pw);
            // 换账号后丢掉上一用户的 settings 内存缓存。
            KotvSettingsCache.clear();
            if (ctx.mounted) Navigator.pop(ctx, true);
          } catch (e) {
            if (ctx.mounted) showAppNews(ctx, '$e');
          } finally {
            if (ctx.mounted) setLocal(() => busy = false);
          }
        }

        return Dialog(
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
                KotvTvTextField(
                  controller: userCtrl,
                  autofocus: userCtrl.text.isEmpty,
                  keyboardType: TextInputType.text,
                  textInputAction: TextInputAction.next,
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
                KotvTvTextField(
                  controller: passCtrl,
                  autofocus: userCtrl.text.isNotEmpty,
                  obscureText: true,
                  keyboardType: TextInputType.visiblePassword,
                  textInputAction: TextInputAction.done,
                  onSubmitted: (_) => submit(),
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
                    child: KotvFocusAction(
                      label: modeRegister ? '已有账号？去登录' : '没有账号？注册',
                      color: p.primary,
                      onPressed: () => setLocal(() => modeRegister = !modeRegister),
                    ),
                  ),
                ],
                const SizedBox(height: 12),
                Row(
                  children: [
                    if (allowCancel) ...[
                      Expanded(
                        child: KotvFocusAction(
                          label: '取消',
                          color: p.muted,
                          onPressed: () => Navigator.pop(ctx, false),
                        ),
                      ),
                      const SizedBox(width: 8),
                    ],
                    Expanded(
                      child: KotvFocusAction(
                        label: modeRegister ? '注册并登录' : '登录',
                        filled: true,
                        onPressed: submit,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        );
      },
    ),
  );
  return ok == true;
}
