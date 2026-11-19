import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/kotv_client_store.dart';
import '../api/kotv_settings_cache.dart';
import '../providers.dart';
import '../theme/kotv_palette.dart';
import '../theme/layout_scale.dart';
import 'chrome.dart';
import 'kotv_tv_text_field.dart';

/// Flutter Web 全页登录：未登录不能进入任何业务页。
class KotvWebSignInPage extends ConsumerStatefulWidget {
  const KotvWebSignInPage({super.key, this.allowRegister = false, this.engineLabel = ''});

  final bool allowRegister;
  final String engineLabel;

  @override
  ConsumerState<KotvWebSignInPage> createState() => _KotvWebSignInPageState();
}

class _KotvWebSignInPageState extends ConsumerState<KotvWebSignInPage> {
  final _userCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  var _register = false;
  var _busy = false;
  String _error = '';

  @override
  void initState() {
    super.initState();
    KotvClientStore.remoteUsername().then((u) {
      if (!mounted || u.isEmpty) return;
      _userCtrl.text = u;
      setState(() {});
    });
  }

  @override
  void dispose() {
    _userCtrl.dispose();
    _passCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_busy) return;
    final u = _userCtrl.text.trim();
    final pw = _passCtrl.text;
    if (u.isEmpty || pw.isEmpty) {
      setState(() => _error = '请填写用户名和密码');
      return;
    }
    setState(() {
      _busy = true;
      _error = '';
    });
    try {
      final api = ref.read(apiProvider);
      if (_register) await api.register(u, pw);
      await api.login(u, pw);
      KotvSettingsCache.clear();
      ref.invalidate(settingsProvider);
      ref.invalidate(engineStatusProvider);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = KotvPalette.of(context);
    final wide = MediaQuery.sizeOf(context).width >= 720;
    return AppBackdrop(
      child: Scaffold(
        backgroundColor: Colors.transparent,
        body: Center(
          child: SingleChildScrollView(
            padding: EdgeInsets.symmetric(
              horizontal: LayoutScale.dp(context, wide ? 24 : 20),
              vertical: 28,
            ),
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: wide ? 420 : 400),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(22),
                  border: Border.all(color: p.pillBorder),
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      p.dialogBg.withOpacity(0.92),
                      p.surface.withOpacity(0.88),
                    ],
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: p.primary.withOpacity(0.18),
                      blurRadius: 36,
                      offset: const Offset(0, 18),
                    ),
                  ],
                ),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(28, 28, 28, 24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          Container(
                            width: 52,
                            height: 52,
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(14),
                              gradient: LinearGradient(
                                begin: Alignment.topLeft,
                                end: Alignment.bottomRight,
                                colors: [p.primary, p.gradEnd],
                              ),
                              boxShadow: [
                                BoxShadow(
                                  color: p.primary.withOpacity(0.35),
                                  blurRadius: 16,
                                  offset: const Offset(0, 8),
                                ),
                              ],
                            ),
                            child: const Text(
                              'KO',
                              style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 18),
                            ),
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'KO影视',
                                  style: TextStyle(
                                    color: p.fg,
                                    fontSize: 24,
                                    fontWeight: FontWeight.w800,
                                    letterSpacing: -0.4,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  _register ? '创建账号后即可观看' : '登录后即可观看全部内容',
                                  style: TextStyle(color: p.muted, fontSize: 13, height: 1.35),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      if (widget.engineLabel.isNotEmpty) ...[
                        const SizedBox(height: 14),
                        Text(widget.engineLabel, style: TextStyle(color: p.muted, fontSize: 12)),
                      ],
                      const SizedBox(height: 22),
                      KotvTvTextField(
                        controller: _userCtrl,
                        autofocus: _userCtrl.text.isEmpty,
                        style: TextStyle(color: p.fg),
                        decoration: InputDecoration(
                          hintText: '用户名',
                          hintStyle: TextStyle(color: p.muted),
                          filled: true,
                          fillColor: p.input,
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide.none,
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      KotvTvTextField(
                        controller: _passCtrl,
                        obscureText: true,
                        autofocus: _userCtrl.text.isNotEmpty,
                        onSubmitted: (_) => _submit(),
                        style: TextStyle(color: p.fg),
                        decoration: InputDecoration(
                          hintText: '密码',
                          hintStyle: TextStyle(color: p.muted),
                          filled: true,
                          fillColor: p.input,
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide.none,
                          ),
                        ),
                      ),
                      if (_error.isNotEmpty) ...[
                        const SizedBox(height: 12),
                        Text(_error, style: TextStyle(color: const Color(0xFFFF8A80), fontSize: 13)),
                      ],
                      if (widget.allowRegister) ...[
                        const SizedBox(height: 10),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: TextButton(
                            onPressed: _busy ? null : () => setState(() => _register = !_register),
                            child: Text(
                              _register ? '已有账号？去登录' : '没有账号？注册',
                              style: TextStyle(color: p.primary),
                            ),
                          ),
                        ),
                      ],
                      const SizedBox(height: 16),
                      SizedBox(
                        height: 48,
                        child: FilledButton(
                          onPressed: _busy ? null : _submit,
                          style: FilledButton.styleFrom(
                            backgroundColor: p.primary,
                            foregroundColor: Colors.white,
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
                          ),
                          child: _busy
                              ? const SizedBox(
                                  width: 22,
                                  height: 22,
                                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                                )
                              : Text(_register ? '注册并登录' : '进入 KO影视', style: const TextStyle(fontWeight: FontWeight.w700)),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
