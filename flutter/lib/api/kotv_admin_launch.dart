import 'package:flutter/material.dart';

import 'kotv_client_store.dart';
import 'kotv_engine_url.dart';
import '../util/kotv_open_url.dart';
import '../widgets/chrome.dart';

/// 解析当前（或指定）引擎的浏览器根地址，末尾带 `/`。
/// 本机空地址会落到 `http://127.0.0.1:9978/`；远端用前端已配置的后端地址。
Future<Uri> kotvEngineWebRootUri({String? engineBaseUrl}) async {
  final raw = (engineBaseUrl != null && engineBaseUrl.trim().isNotEmpty)
      ? engineBaseUrl.trim()
      : await KotvClientStore.effectiveEngineBaseUrl();
  final base = kotvEffectiveEngineBaseUrl(raw);
  final root = base.endsWith('/') ? base : '$base/';
  return Uri.parse(root);
}

/// 引擎 Web 管理控制台：`{root}admin/`。
Future<Uri> kotvAdminConsoleUri({String? engineBaseUrl}) async {
  final root = await kotvEngineWebRootUri(engineBaseUrl: engineBaseUrl);
  return root.resolve('admin/');
}

Future<void> kotvOpenInExternalBrowser(BuildContext context, Uri uri) async {
  final ok = await kotvOpenExternalUrl(uri.toString());
  if (!context.mounted) return;
  if (!ok) {
    showAppNews(context, '请用浏览器打开：\n$uri');
  }
}

/// 浏览器打开遥控入口（引擎根路径；本机即 127.0.0.1:端口）。
Future<void> kotvOpenRemoteConsole(
  BuildContext context, {
  String? engineBaseUrl,
}) async {
  final uri = await kotvEngineWebRootUri(engineBaseUrl: engineBaseUrl);
  if (!context.mounted) return;
  await kotvOpenInExternalBrowser(context, uri);
}

/// 浏览器打开 Web 管理控制台。
Future<void> kotvOpenAdminConsole(
  BuildContext context, {
  String? engineBaseUrl,
}) async {
  final uri = await kotvAdminConsoleUri(engineBaseUrl: engineBaseUrl);
  if (!context.mounted) return;
  await kotvOpenInExternalBrowser(context, uri);
}
