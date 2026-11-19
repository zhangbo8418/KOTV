import 'package:flutter/foundation.dart' show kIsWeb;

import '../api/kotv_api.dart';
import '../api/kotv_engine_url.dart';

/// 当前引擎是否为本机（127.0.0.1 / localhost）。
bool kotvIsLocalEngine(String engineBaseUrl) =>
    kotvIsLocalEngineBaseUrl(engineBaseUrl);

/// 远端已登录且角色为 admin。
Future<bool> kotvRemoteIsAdmin(KotvApi api) async {
  try {
    final me = await api.authMe();
    final user = Map<String, dynamic>.from((me['user'] as Map?) ?? const {});
    return '${user['role'] ?? ''}' == 'admin';
  } catch (_) {
    return false;
  }
}

/// 可增删改共享仓/直播源、清缓存、管主机设置、进入用户管理：
/// - Web 客户端：仅管理员（浏览器始终按远端处理）
/// - 原生连本机引擎：本机机主
/// - 原生连远端：已登录管理员
Future<bool> kotvCanManageShared(KotvApi api, String engineBaseUrl) async {
  if (kIsWeb) return kotvRemoteIsAdmin(api);
  if (kotvIsLocalEngine(engineBaseUrl)) return true;
  return kotvRemoteIsAdmin(api);
}
