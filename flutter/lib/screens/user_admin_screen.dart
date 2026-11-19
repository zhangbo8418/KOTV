import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/kotv_api.dart';
import '../api/kotv_auth_token.dart';
import '../api/kotv_engine_url.dart';
import '../providers.dart';
import '../theme/kotv_palette.dart';
import '../theme/layout_scale.dart';
import '../theme/kotv_theme.dart';
import '../policy/group_policy.dart';
import '../widgets/chrome.dart';
import '../widgets/dialogs.dart';
import '../widgets/kotv_tv_text_field.dart';
import 'shell.dart';

/// 应用内轻量用户管理：远端鉴权（仅原生）、账号/角色/分组、注册审批；完整策略走 Web 管理控制台。
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
  bool _requireApproval = false;
  List<Map<String, dynamic>> _users = [];
  List<Map<String, dynamic>> _groups = [];
  Map<String, dynamic>? _me;
  bool _forceChangeShown = false;
  String _deviceIp = '';
  List<String> _deviceIpv4 = [];
  List<String> _deviceIpv6 = [];
  String _devicePublicIp = '';
  String _devicePort = '$kotvDefaultEnginePort';

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
      try {
        final st = await _api.getSettings();
        _devicePort = '${st['port'] ?? kotvDefaultEnginePort}';
      } catch (_) {}
      try {
        final dev = await _api.getDevice();
        var ip = '${dev['ip'] ?? ''}'.trim();
        if (ip.contains('://')) {
          try {
            ip = Uri.parse(ip).host;
          } catch (_) {}
        }
        if (ip == '127.0.0.1' || ip == '::1' || ip == 'localhost') {
          ip = '';
        }
        _deviceIp = ip;
        _deviceIpv4 = ((dev['ipv4'] as List?) ?? const [])
            .map((e) => '$e'.trim())
            .where((e) => e.isNotEmpty && e != '127.0.0.1')
            .toList();
        _deviceIpv6 = ((dev['ipv6'] as List?) ?? const [])
            .map((e) => '$e'.trim())
            .where((e) => e.isNotEmpty && e != '::1')
            .toList();
        _devicePublicIp = '${dev['publicIp'] ?? ''}'.trim();
        if (_deviceIp.isEmpty && _deviceIpv4.isNotEmpty) {
          _deviceIp = _deviceIpv4.first;
        }
        if (_deviceIp.isEmpty && _devicePublicIp.isNotEmpty) {
          _deviceIp = _devicePublicIp;
        }
      } catch (_) {
        _deviceIp = '';
        _deviceIpv4 = [];
        _deviceIpv6 = [];
        _devicePublicIp = '';
      }
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
      var groups = <Map<String, dynamic>>[];
      try {
        final gdata = await _api.adminListGroups();
        groups = ((gdata['groups'] as List?) ?? const [])
            .whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList();
        groups.sort((a, b) {
          final sa = (a['sort'] is num) ? (a['sort'] as num).toInt() : 0;
          final sb = (b['sort'] is num) ? (b['sort'] as num).toInt() : 0;
          if (sa != sb) return sa.compareTo(sb);
          return '${a['name']}'.compareTo('${b['name']}');
        });
      } catch (_) {
        groups = [];
      }
      if (!mounted) return;
      setState(() {
        _me = user;
        _isAdmin = true;
        _remoteAuth = data['remoteAuth'] == true;
        _allowRegister = data['allowRegister'] == true;
        _requireApproval = data['requireApproval'] == true;
        _users = list;
        _groups = groups;
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
          width: LayoutScale.dp(ctx, 360),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('管理用户需管理员账号。新装默认 admin / admin。', style: TextStyle(color: p.muted, fontSize: 13)),
              const SizedBox(height: 12),
              KotvTvTextField(
                controller: userCtrl,
                autofocus: true,
                style: TextStyle(color: p.fg),
                decoration: InputDecoration(hintText: '用户名', hintStyle: TextStyle(color: p.muted)),
              ),
              const SizedBox(height: 10),
              KotvTvTextField(
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
          KotvFocusAction(label: '取消', color: p.muted, onPressed: () => Navigator.pop(ctx, false)),
          KotvFocusAction(label: '登录', filled: true, onPressed: () => Navigator.pop(ctx, true)),
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

  Future<void> _setFlag({
    bool? remoteAuth,
    bool? allowRegister,
    bool? requireApproval,
  }) async {
    setState(() => _busy = true);
    try {
      // 开启开放注册时一并打开审批（后端也会默认打开）。
      final approval = requireApproval ??
          (allowRegister == true && !_requireApproval ? true : null);
      final data = await _api.adminSetSettings(
        remoteAuth: remoteAuth,
        allowRegister: allowRegister,
        requireApproval: approval,
      );
      if (!mounted) return;
      setState(() {
        _remoteAuth = data['remoteAuth'] == true;
        _allowRegister = data['allowRegister'] == true;
        _requireApproval = data['requireApproval'] == true;
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

  List<Map<String, dynamic>> get _pendingUsers => _users
      .where((u) => '${u['status'] ?? ''}' == 'pending')
      .toList(growable: false);

  String _groupLabel(String groupId) {
    final id = groupId.trim().isEmpty ? 'default' : groupId.trim();
    for (final g in _groups) {
      if ('${g['id']}' == id) {
        final name = '${g['name'] ?? ''}'.trim();
        return name.isEmpty ? id : name;
      }
    }
    return id;
  }

  List<DropdownMenuItem<String>> _groupMenuItems() {
    if (_groups.isEmpty) {
      return const [DropdownMenuItem(value: 'default', child: Text('默认'))];
    }
    return _groups
        .map(
          (g) => DropdownMenuItem<String>(
            value: '${g['id']}',
            child: Text('${g['name'] ?? g['id']}'),
          ),
        )
        .toList();
  }

  Future<void> _createUser() async {
    final p = KotvPalette.of(context);
    final userCtrl = TextEditingController();
    final passCtrl = TextEditingController();
    var role = 'user';
    var groupId = _groups.isNotEmpty ? '${_groups.first['id']}' : 'default';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          backgroundColor: p.dialogBg,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          title: Text('创建账号', style: TextStyle(color: p.fg, fontWeight: FontWeight.w700)),
          content: SizedBox(
            width: LayoutScale.dp(ctx, 360),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                KotvTvTextField(
                  controller: userCtrl,
                  autofocus: true,
                  style: TextStyle(color: p.fg),
                  decoration: InputDecoration(hintText: '用户名', hintStyle: TextStyle(color: p.muted)),
                ),
                const SizedBox(height: 10),
                KotvTvTextField(
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
                      focusColor: p.focus.withOpacity(0.28),
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
                const SizedBox(height: 8),
                Row(
                  children: [
                    Text('分组', style: TextStyle(color: p.muted)),
                    const Spacer(),
                    DropdownButton<String>(
                      value: _groupMenuItems().any((e) => e.value == groupId) ? groupId : _groupMenuItems().first.value,
                      focusColor: p.focus.withOpacity(0.28),
                      dropdownColor: p.dialogBg,
                      style: TextStyle(color: p.fg),
                      items: _groupMenuItems(),
                      onChanged: (v) {
                        if (v == null) return;
                        setLocal(() => groupId = v);
                      },
                    ),
                  ],
                ),
              ],
            ),
          ),
          actions: [
            KotvFocusAction(label: '取消', color: p.muted, onPressed: () => Navigator.pop(ctx, false)),
            KotvFocusAction(label: '创建', filled: true, onPressed: () => Navigator.pop(ctx, true)),
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
        groupId: groupId,
      );
      setState(() => _status = '已创建 ${userCtrl.text.trim()}');
      await _refresh();
    } catch (e) {
      if (!mounted) return;
      setState(() => _status = '创建失败: $e');
    }
  }

  Future<void> _setUserRole(Map<String, dynamic> u) async {
    final id = '${u['id'] ?? ''}';
    final name = '${u['username'] ?? ''}';
    if (id.isEmpty) return;
    final p = KotvPalette.of(context);
    var role = '${u['role'] ?? 'user'}' == 'admin' ? 'admin' : 'user';
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          backgroundColor: p.dialogBg,
          title: Text('角色 · $name', style: TextStyle(color: p.fg)),
          content: DropdownButton<String>(
            value: role,
            isExpanded: true,
            focusColor: p.focus.withOpacity(0.28),
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
          actions: [
            KotvFocusAction(label: '取消', color: p.muted, onPressed: () => Navigator.pop(ctx, false)),
            KotvFocusAction(label: '保存', filled: true, onPressed: () => Navigator.pop(ctx, true)),
          ],
        ),
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await _api.adminSetUserRole(id, role);
      setState(() => _status = '已更新 $name 角色');
      await _refresh();
    } catch (e) {
      if (!mounted) return;
      setState(() => _status = '角色失败: $e');
    }
  }

  Future<void> _approveUser(Map<String, dynamic> u) async {
    final id = '${u['id'] ?? ''}';
    final name = '${u['username'] ?? ''}';
    if (id.isEmpty) return;
    try {
      await _api.adminApproveUser(id);
      setState(() => _status = '已审批 $name');
      await _refresh();
    } catch (e) {
      if (!mounted) return;
      setState(() => _status = '审批失败: $e');
    }
  }

  Future<void> _setUserGroup(Map<String, dynamic> u) async {
    final id = '${u['id'] ?? ''}';
    final name = '${u['username'] ?? ''}';
    if (id.isEmpty) return;
    if (_groups.isEmpty) {
      setState(() => _status = '暂无分组，请先在管理控制台创建分组');
      return;
    }
    final p = KotvPalette.of(context);
    var groupId = '${u['groupId'] ?? 'default'}';
    if (!_groupMenuItems().any((e) => e.value == groupId)) {
      groupId = _groupMenuItems().first.value!;
    }
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          backgroundColor: p.dialogBg,
          title: Text('分组 · $name', style: TextStyle(color: p.fg)),
          content: DropdownButton<String>(
            value: groupId,
            isExpanded: true,
            focusColor: p.focus.withOpacity(0.28),
            dropdownColor: p.dialogBg,
            style: TextStyle(color: p.fg),
            items: _groupMenuItems(),
            onChanged: (v) {
              if (v == null) return;
              setLocal(() => groupId = v);
            },
          ),
          actions: [
            KotvFocusAction(label: '取消', color: p.muted, onPressed: () => Navigator.pop(ctx, false)),
            KotvFocusAction(label: '保存', filled: true, onPressed: () => Navigator.pop(ctx, true)),
          ],
        ),
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await _api.adminSetUserGroup(id, groupId);
      setState(() => _status = '已更新 $name 分组');
      await _refresh();
    } catch (e) {
      if (!mounted) return;
      setState(() => _status = '分组失败: $e');
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
        content: KotvTvTextField(
          controller: passCtrl,
          obscureText: true,
          autofocus: true,
          style: TextStyle(color: p.fg),
          decoration: InputDecoration(hintText: '新密码（至少 6 位）', hintStyle: TextStyle(color: p.muted)),
        ),
        actions: [
          KotvFocusAction(label: '取消', color: p.muted, onPressed: () => Navigator.pop(ctx, false)),
          KotvFocusAction(label: '确定', filled: true, onPressed: () => Navigator.pop(ctx, true)),
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
            KotvFocusAction(label: '取消', color: p.muted, autofocus: true, onPressed: () => Navigator.pop(ctx, false)),
            KotvFocusAction(
              label: '删除',
              filled: true,
              fillColor: const Color(0xFFE53955),
              onPressed: () => Navigator.pop(ctx, true),
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
          width: LayoutScale.dp(ctx, 360),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (forced)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text('初始管理员仍在使用默认密码，请先修改后再继续。', style: TextStyle(color: p.muted, fontSize: 13)),
                ),
              KotvTvTextField(
                controller: oldCtrl,
                obscureText: true,
                autofocus: true,
                style: TextStyle(color: p.fg),
                decoration: InputDecoration(hintText: '旧密码', hintStyle: TextStyle(color: p.muted)),
              ),
              const SizedBox(height: 10),
              KotvTvTextField(
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
            KotvFocusAction(label: '取消', color: p.muted, onPressed: () => Navigator.pop(ctx, false)),
          KotvFocusAction(label: '保存', filled: true, onPressed: () => Navigator.pop(ctx, true)),
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
            onNews: () => showLatestNews(context, ref),
            title: '用户管理',
          ),
          if (_deviceIp.isNotEmpty || _deviceIpv4.isNotEmpty || _deviceIpv6.isNotEmpty || _devicePublicIp.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 0),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  [
                    if (_deviceIpv4.isNotEmpty)
                      '本机 IPv4: ${_deviceIpv4.join(', ')}'
                    else if (_deviceIp.isNotEmpty)
                      '本机 IP: $_deviceIp',
                    if (_deviceIpv6.isNotEmpty) 'IPv6: ${_deviceIpv6.join(', ')}',
                    if (_devicePublicIp.isNotEmpty &&
                        !_deviceIpv4.contains(_devicePublicIp) &&
                        _deviceIp != _devicePublicIp)
                      '公网 IPv4: $_devicePublicIp',
                    if (_deviceIp.isNotEmpty || _deviceIpv4.isNotEmpty)
                      '访问 http://${_deviceIp.isNotEmpty ? _deviceIp : _deviceIpv4.first}:$_devicePort/'
                    else if (_deviceIpv6.isNotEmpty)
                      '访问 http://[${_deviceIpv6.first}]:$_devicePort/'
                    else if (_devicePublicIp.isNotEmpty)
                      '公网探测（未必可作局域网入口）: $_devicePublicIp',
                  ].where((e) => e.isNotEmpty).join('\n'),
                  style: TextStyle(color: p.muted, fontSize: 13, height: 1.35),
                ),
              ),
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
                          const KotvSettingsSectionTitle('访问与注册'),
                          KotvSettingsCard(children: [
                            // Flutter Web 本身始终鉴权，不提供「远端鉴权」主机开关；该开关只影响局域网 App。
                            if (!kIsWeb)
                              TvFocus(
                                onPressed: _busy ? null : () => unawaited(_setFlag(remoteAuth: !_remoteAuth)),
                                borderRadius: 8,
                                scrollIntoView: true,
                                child: ExcludeFocus(
                                  child: SwitchListTile(
                                    title: Text('开启远端鉴权', style: TextStyle(color: p.fg)),
                                    subtitle: Text(
                                      '默认关闭：仅本机 App 免登录。开启后局域网其它 App 须登录。本机浏览器打开的遥控/管理台始终免登录；Flutter Web 始终须登录。',
                                      style: TextStyle(color: p.muted, fontSize: 12),
                                    ),
                                    value: _remoteAuth,
                                    onChanged: _busy ? null : (v) => unawaited(_setFlag(remoteAuth: v)),
                                  ),
                                ),
                              ),
                            if (kIsWeb)
                              ListTile(
                                title: Text('Web 客户端鉴权', style: TextStyle(color: p.fg)),
                                subtitle: Text(
                                  'Flutter Web 始终需要登录，无法关闭。',
                                  style: TextStyle(color: p.muted, fontSize: 12),
                                ),
                              ),
                            TvFocus(
                              onPressed: _busy ? null : () => unawaited(_setFlag(allowRegister: !_allowRegister)),
                              borderRadius: 8,
                              scrollIntoView: true,
                              child: ExcludeFocus(
                                child: SwitchListTile(
                                  title: Text('开放注册', style: TextStyle(color: p.fg)),
                                  subtitle: Text('允许访客自行注册普通账号；开启时默认需要审批', style: TextStyle(color: p.muted, fontSize: 12)),
                                  value: _allowRegister,
                                  onChanged: _busy ? null : (v) => unawaited(_setFlag(allowRegister: v)),
                                ),
                              ),
                            ),
                            if (_allowRegister || _requireApproval)
                              TvFocus(
                                onPressed: _busy
                                    ? null
                                    : () => unawaited(_setFlag(requireApproval: !_requireApproval)),
                                borderRadius: 8,
                                scrollIntoView: true,
                                child: ExcludeFocus(
                                  child: SwitchListTile(
                                    title: Text('注册需审批', style: TextStyle(color: p.fg)),
                                    subtitle: Text('新注册账号须管理员通过后才能登录', style: TextStyle(color: p.muted, fontSize: 12)),
                                    value: _requireApproval,
                                    onChanged: _busy
                                        ? null
                                        : (v) => unawaited(_setFlag(requireApproval: v)),
                                  ),
                                ),
                              ),
                          ]),
                          if (_allowRegister || _requireApproval || _pendingUsers.isNotEmpty) ...[
                            const SizedBox(height: 8),
                            const KotvSettingsSectionTitle('注册审批'),
                            if (_pendingUsers.isEmpty)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 8),
                                child: Text('暂无待审批账号', style: TextStyle(color: p.muted, fontSize: 13)),
                              )
                            else
                              ..._pendingUsers.map((u) {
                                final name = '${u['username'] ?? ''}';
                                final groupLabel = _groupLabel('${u['groupId'] ?? ''}');
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
                                            child: Text(
                                              '$name · 分组 $groupLabel · 待审批',
                                              style: TextStyle(color: p.fg, fontSize: 14),
                                            ),
                                          ),
                                          KotvFocusAction(
                                            label: '通过',
                                            filled: true,
                                            fontSize: 12,
                                            onPressed: () => unawaited(_approveUser(u)),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                );
                              }),
                          ],
                          const SizedBox(height: 8),
                          const KotvSettingsSectionTitle('账号'),
                          Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: Text(
                              '分组策略、品牌、公告等：可返回设置长按「用户管理」在浏览器打开管理台。',
                              style: TextStyle(color: p.muted, fontSize: 12),
                            ),
                          ),
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
                            final pending = '${u['status'] ?? ''}' == 'pending';
                            final roleLabel = role == 'admin' ? '管理员' : '用户';
                            final groupLabel = _groupLabel('${u['groupId'] ?? ''}');
                            final statusLabel = pending
                                ? '待审批'
                                : (enabled ? '启用' : '停用');
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
                                              '$roleLabel · 分组 $groupLabel · $statusLabel${must ? ' · 需改密' : ''}',
                                              style: TextStyle(color: p.muted, fontSize: 12),
                                            ),
                                          ],
                                        ),
                                      ),
                                      if (pending)
                                        KotvFocusAction(
                                          label: '审批',
                                          color: p.fg,
                                          fontSize: 12,
                                          onPressed: () => unawaited(_approveUser(u)),
                                        ),
                                      KotvFocusAction(
                                        label: '角色',
                                        color: p.fg,
                                        fontSize: 12,
                                        onPressed: () => unawaited(_setUserRole(u)),
                                      ),
                                      KotvFocusAction(
                                        label: '分组',
                                        color: p.fg,
                                        fontSize: 12,
                                        onPressed: () => unawaited(_setUserGroup(u)),
                                      ),
                                      KotvFocusAction(
                                        label: enabled ? '停用' : '启用',
                                        color: p.fg,
                                        fontSize: 12,
                                        onPressed: () => unawaited(_toggleEnabled(u)),
                                      ),
                                      KotvFocusAction(
                                        label: '重置密码',
                                        color: p.fg,
                                        fontSize: 12,
                                        onPressed: () => unawaited(_resetPassword(u)),
                                      ),
                                      KotvFocusAction(
                                        label: '删除',
                                        color: const Color(0xFFE53955),
                                        fontSize: 12,
                                        onPressed: () => unawaited(_deleteUser(u)),
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
