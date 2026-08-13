import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/kotv_api.dart';
import '../api/kotv_auth_token.dart';
import '../providers.dart';
import '../theme/kotv_palette.dart';
import '../theme/layout_scale.dart';
import '../widgets/chrome.dart';
import '../widgets/dialogs.dart';
import 'shell.dart';

/// 本机引擎用户管理（`/admin`）：鉴权/注册开关、账号 CRUD、改密。
class UserAdminScreen extends ConsumerStatefulWidget {
  const UserAdminScreen({super.key});

  @override
  ConsumerState<UserAdminScreen> createState() => _UserAdminScreenState();
}

class _UserAdminScreenState extends ConsumerState<UserAdminScreen> {
  bool _loading = true;
  bool _busy = false;
  String _status = '';
  bool _isAdmin = false;
  bool _remoteAuth = false;
  bool _allowRegister = false;
  List<Map<String, dynamic>> _users = [];
  Map<String, dynamic>? _me;
  bool _forceChangeShown = false;

  KotvApi get _api => ref.read(apiProvider);

  @override
  void initState() {
    super.initState();
    unawaited(_bootstrap());
  }

  Future<void> _bootstrap() async {
    setState(() {
      _loading = true;
      _status = '';
    });
    try {
      // 本机（loopback）管理免登录；非本机才要管理员。
      final st = await _api.authStatus();
      final adminRequired = st['adminRequired'] == true;
      final tok = await kotvAuthToken();
      if (adminRequired && tok.isEmpty) {
        if (!mounted) return;
        setState(() {
          _loading = false;
          _isAdmin = false;
        });
        await _promptAdminLogin();
        return;
      }
      await _refresh();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _status = '$e';
        _isAdmin = false;
      });
      await _promptAdminLogin();
    }
  }

  Future<void> _refresh() async {
    setState(() => _busy = true);
    try {
      final me = await _api.authMe();
      final user = Map<String, dynamic>.from((me['user'] as Map?) ?? const {});
      final role = '${user['role'] ?? ''}';
      if (role != 'admin') {
        if (!mounted) return;
        setState(() {
          _loading = false;
          _busy = false;
          _isAdmin = false;
          _me = user;
          _status = '当前账号不是管理员，请使用管理员登录';
        });
        await _promptAdminLogin();
        return;
      }
      final data = await _api.adminListUsers();
      final list = ((data['users'] as List?) ?? const [])
          .whereType<Map>()
          .map((e) => Map<String, dynamic>.from(e))
          .toList();
      list.sort((a, b) => '${a['username']}'.compareTo('${b['username']}'));
      if (!mounted) return;
      setState(() {
        _me = user;
        _isAdmin = true;
        _remoteAuth = data['remoteAuth'] == true;
        _allowRegister = data['allowRegister'] == true;
        _users = list;
        _loading = false;
        _busy = false;
        _status = '';
      });
      if (user['mustChangePassword'] == true && !_forceChangeShown) {
        _forceChangeShown = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) unawaited(_changeOwnPassword(forced: true));
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _busy = false;
        _isAdmin = false;
        _status = '$e';
      });
      final s = '$e';
      if (s.contains('需要登录') || s.contains('需要管理员') || s.contains('登录已失效') || s.contains('401') || s.contains('403')) {
        await _promptAdminLogin();
      }
    }
  }

  Future<void> _promptAdminLogin() async {
    final p = KotvPalette.of(context);
    final userCtrl = TextEditingController(text: 'admin');
    final passCtrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: p.dialogBg,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        title: Text('管理员登录', style: TextStyle(color: p.fg, fontWeight: FontWeight.w700)),
        content: SizedBox(
          width: 360,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('管理用户需管理员账号。新装默认 admin / admin。', style: TextStyle(color: p.muted, fontSize: 13)),
              const SizedBox(height: 12),
              TextField(
                controller: userCtrl,
                autofocus: true,
                style: TextStyle(color: p.fg),
                decoration: InputDecoration(hintText: '用户名', hintStyle: TextStyle(color: p.muted)),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: passCtrl,
                obscureText: true,
                style: TextStyle(color: p.fg),
                decoration: InputDecoration(hintText: '密码', hintStyle: TextStyle(color: p.muted)),
                onSubmitted: (_) => Navigator.pop(ctx, true),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text('取消', style: TextStyle(color: p.muted))),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('登录')),
        ],
      ),
    );
    if (ok != true || !mounted) {
      if (mounted && !_isAdmin) Navigator.of(context).maybePop();
      return;
    }
    try {
      await _api.login(userCtrl.text.trim(), passCtrl.text);
      await _refresh();
    } catch (e) {
      if (!mounted) return;
      setState(() => _status = '登录失败: $e');
      await _promptAdminLogin();
    }
  }

  Future<void> _setFlag({bool? remoteAuth, bool? allowRegister}) async {
    setState(() => _busy = true);
    try {
      final data = await _api.adminSetSettings(remoteAuth: remoteAuth, allowRegister: allowRegister);
      if (!mounted) return;
      setState(() {
        _remoteAuth = data['remoteAuth'] == true;
        _allowRegister = data['allowRegister'] == true;
        _busy = false;
        _status = '已保存';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _status = '$e';
      });
    }
  }

  Future<void> _createUser() async {
    final p = KotvPalette.of(context);
    final userCtrl = TextEditingController();
    final passCtrl = TextEditingController();
    var role = 'user';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          backgroundColor: p.dialogBg,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          title: Text('创建账号', style: TextStyle(color: p.fg, fontWeight: FontWeight.w700)),
          content: SizedBox(
            width: 360,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: userCtrl,
                  autofocus: true,
                  style: TextStyle(color: p.fg),
                  decoration: InputDecoration(hintText: '用户名', hintStyle: TextStyle(color: p.muted)),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: passCtrl,
                  obscureText: true,
                  style: TextStyle(color: p.fg),
                  decoration: InputDecoration(hintText: '密码（至少 6 位）', hintStyle: TextStyle(color: p.muted)),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Text('角色', style: TextStyle(color: p.muted)),
                    const Spacer(),
                    DropdownButton<String>(
                      value: role,
                      dropdownColor: p.dialogBg,
                      style: TextStyle(color: p.fg),
                      items: const [
                        DropdownMenuItem(value: 'user', child: Text('普通用户')),
                        DropdownMenuItem(value: 'admin', child: Text('管理员')),
                      ],
                      onChanged: (v) {
                        if (v == null) return;
                        setLocal(() => role = v);
                      },
                    ),
                  ],
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text('取消', style: TextStyle(color: p.muted))),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('创建')),
          ],
        ),
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await _api.adminCreateUser(
        username: userCtrl.text.trim(),
        password: passCtrl.text,
        role: role,
      );
      setState(() => _status = '已创建 ${userCtrl.text.trim()}');
      await _refresh();
    } catch (e) {
      if (!mounted) return;
      setState(() => _status = '创建失败: $e');
    }
  }

  Future<void> _resetPassword(Map<String, dynamic> u) async {
    final id = '${u['id'] ?? ''}';
    final name = '${u['username'] ?? ''}';
    if (id.isEmpty) return;
    final p = KotvPalette.of(context);
    final passCtrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: p.dialogBg,
        title: Text('重置密码 · $name', style: TextStyle(color: p.fg)),
        content: TextField(
          controller: passCtrl,
          obscureText: true,
          autofocus: true,
          style: TextStyle(color: p.fg),
          decoration: InputDecoration(hintText: '新密码（至少 6 位）', hintStyle: TextStyle(color: p.muted)),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text('取消', style: TextStyle(color: p.muted))),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('确定')),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await _api.adminResetPassword(id, passCtrl.text);
      setState(() => _status = '已重置 $name 的密码');
    } catch (e) {
      if (!mounted) return;
      setState(() => _status = '重置失败: $e');
    }
  }

  Future<void> _toggleEnabled(Map<String, dynamic> u) async {
    final id = '${u['id'] ?? ''}';
    final name = '${u['username'] ?? ''}';
    final enabled = u['enabled'] == true;
    if (id.isEmpty) return;
    try {
      if (enabled) {
        await _api.adminDisableUser(id);
        setState(() => _status = '已停用 $name');
      } else {
        await _api.adminEnableUser(id);
        setState(() => _status = '已启用 $name');
      }
      await _refresh();
    } catch (e) {
      if (!mounted) return;
      setState(() => _status = '$e');
    }
  }

  Future<void> _deleteUser(Map<String, dynamic> u) async {
    final id = '${u['id'] ?? ''}';
    final name = '${u['username'] ?? ''}';
    if (id.isEmpty) return;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        final p = KotvPalette.of(ctx);
        return AlertDialog(
          backgroundColor: p.dialogBg,
          title: Text('删除账号', style: TextStyle(color: p.fg)),
          content: Text('确定删除 $name？', style: TextStyle(color: p.muted)),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text('取消', style: TextStyle(color: p.muted))),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: const Color(0xFFE53955)),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('删除'),
            ),
          ],
        );
      },
    );
    if (confirm != true || !mounted) return;
    try {
      await _api.adminDeleteUser(id);
      setState(() => _status = '已删除 $name');
      await _refresh();
    } catch (e) {
      if (!mounted) return;
      setState(() => _status = '删除失败: $e');
    }
  }

  Future<void> _changeOwnPassword({bool forced = false}) async {
    // 本机免登录的「本机」机主：改密请用列表重置。
    final meId = '${_me?['id'] ?? ''}';
    if (meId.isEmpty && '${_me?['username'] ?? ''}' == '本机') {
      setState(() => _status = '本机管理免登录：请在下方账号列表重置对应账号密码');
      return;
    }
    final p = KotvPalette.of(context);
    final oldCtrl = TextEditingController();
    final newCtrl = TextEditingController();
    final ok = await showDialog<bool>(
      context: context,
      barrierDismissible: !forced,
      builder: (ctx) => AlertDialog(
        backgroundColor: p.dialogBg,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        title: Text(
          forced ? '请修改默认密码' : '修改我的密码',
          style: TextStyle(color: p.fg, fontWeight: FontWeight.w700),
        ),
        content: SizedBox(
          width: 360,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (forced)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text('初始管理员仍在使用默认密码，请先修改后再继续。', style: TextStyle(color: p.muted, fontSize: 13)),
                ),
              TextField(
                controller: oldCtrl,
                obscureText: true,
                autofocus: true,
                style: TextStyle(color: p.fg),
                decoration: InputDecoration(hintText: '旧密码', hintStyle: TextStyle(color: p.muted)),
              ),
              const SizedBox(height: 10),
              TextField(
                controller: newCtrl,
                obscureText: true,
                style: TextStyle(color: p.fg),
                decoration: InputDecoration(hintText: '新密码（至少 6 位）', hintStyle: TextStyle(color: p.muted)),
              ),
            ],
          ),
        ),
        actions: [
          if (!forced)
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text('取消', style: TextStyle(color: p.muted))),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('保存')),
        ],
      ),
    );
    if (ok != true || !mounted) {
      if (forced && mounted) {
        // 强制改密未完成：再弹一次
        _forceChangeShown = false;
        unawaited(_changeOwnPassword(forced: true));
      }
      return;
    }
    try {
      await _api.changePassword(oldPassword: oldCtrl.text, newPassword: newCtrl.text);
      if (!mounted) return;
      setState(() {
        _status = '密码已修改';
        _me = {...?_me, 'mustChangePassword': false};
      });
      showAppNews(context, '密码已修改');
    } catch (e) {
      if (!mounted) return;
      setState(() => _status = '改密失败: $e');
      if (forced) {
        _forceChangeShown = false;
        unawaited(_changeOwnPassword(forced: true));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = KotvPalette.of(context);
    final compact = KotvLayout.isCompact(context);
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: Column(
        children: [
          LibraryTopBar(
            onBack: () => Navigator.of(context).maybePop(),
            onSearch: () => goKotvPage(ref, KotvPage.search),
            onProfile: () => goKotvPage(ref, KotvPage.profile),
            onNews: () => showAppNews(context, '用户管理：本机免登录。非本机在连接时登录一次即可；管理员可管账号，看片与本机同体验（按账号隔离）。'),
            title: '用户管理',
          ),
          if (_status.isNotEmpty || _busy)
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 0),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: p.pillBg,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: p.pillBorder),
                ),
                child: Row(
                  children: [
                    if (_busy)
                      const Padding(
                        padding: EdgeInsets.only(right: 8),
                        child: SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      ),
                    Expanded(child: Text(_status.isEmpty ? '处理中…' : _status, style: TextStyle(color: p.fg, fontSize: 13))),
                  ],
                ),
              ),
            ),
          Expanded(
            child: _loading
                ? Center(child: CircularProgressIndicator(color: p.primary))
                : !_isAdmin
                    ? Center(child: Text(_status.isEmpty ? '需要管理员登录' : _status, style: TextStyle(color: p.muted)))
                    : ListView(
                        padding: EdgeInsets.fromLTRB(compact ? 16 : 24, 12, compact ? 16 : 24, 24),
                        children: [
                          const KotvSettingsSectionTitle('远端鉴权'),
                          KotvSettingsCard(children: [
                            SwitchListTile(
                              title: Text('开启远端鉴权', style: TextStyle(color: p.fg)),
                              subtitle: Text('开启后非本机前端连接时登录一次，之后与本机同体验并按账号隔离', style: TextStyle(color: p.muted, fontSize: 12)),
                              value: _remoteAuth,
                              onChanged: _busy ? null : (v) => unawaited(_setFlag(remoteAuth: v)),
                            ),
                            SwitchListTile(
                              title: Text('开放远端注册', style: TextStyle(color: p.fg)),
                              subtitle: Text('允许访客自行注册普通账号', style: TextStyle(color: p.muted, fontSize: 12)),
                              value: _allowRegister,
                              onChanged: _busy ? null : (v) => unawaited(_setFlag(allowRegister: v)),
                            ),
                          ]),
                          const SizedBox(height: 8),
                          const KotvSettingsSectionTitle('账号'),
                          KotvSettingsCard(children: [
                            KotvSettingsGrid(columns: compact ? 2 : 3, children: [
                              KotvSettingsCell(label: '创建账号', onTap: () => unawaited(_createUser())),
                              KotvSettingsCell(label: '修改我的密码', onTap: () => unawaited(_changeOwnPassword())),
                              KotvSettingsCell(label: '刷新列表', onTap: () => unawaited(_refresh())),
                            ]),
                          ]),
                          const SizedBox(height: 12),
                          ..._users.map((u) {
                            final name = '${u['username'] ?? ''}';
                            final role = '${u['role'] ?? ''}';
                            final enabled = u['enabled'] == true;
                            final must = u['mustChangePassword'] == true;
                            final roleLabel = role == 'admin' ? '管理员' : '用户';
                            return Padding(
                              padding: const EdgeInsets.only(bottom: 8),
                              child: Material(
                                color: p.pillBg,
                                borderRadius: BorderRadius.circular(12),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                                  child: Row(
                                    children: [
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment: CrossAxisAlignment.start,
                                          children: [
                                            Text(name, style: TextStyle(color: p.fg, fontWeight: FontWeight.w600, fontSize: 15)),
                                            const SizedBox(height: 2),
                                            Text(
                                              '$roleLabel · ${enabled ? '启用' : '停用'}${must ? ' · 需改密' : ''}',
                                              style: TextStyle(color: p.muted, fontSize: 12),
                                            ),
                                          ],
                                        ),
                                      ),
                                      TextButton(
                                        onPressed: () => unawaited(_toggleEnabled(u)),
                                        child: Text(enabled ? '停用' : '启用', style: TextStyle(color: p.fg, fontSize: 12)),
                                      ),
                                      TextButton(
                                        onPressed: () => unawaited(_resetPassword(u)),
                                        child: Text('重置密码', style: TextStyle(color: p.fg, fontSize: 12)),
                                      ),
                                      TextButton(
                                        onPressed: () => unawaited(_deleteUser(u)),
                                        child: const Text('删除', style: TextStyle(color: Color(0xFFE53955), fontSize: 12)),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            );
                          }),
                          if (_users.isEmpty)
                            Padding(
                              padding: const EdgeInsets.only(top: 24),
                              child: Center(child: Text('暂无用户', style: TextStyle(color: p.muted))),
                            ),
                        ],
                      ),
          ),
        ],
      ),
    );
  }
}
