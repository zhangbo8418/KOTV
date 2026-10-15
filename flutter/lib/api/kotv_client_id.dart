import 'kotv_client_store.dart';

String? _cached;

/// 本机 Flutter 实例的稳定 clientId（多前端连同一引擎时用于 UI 路由）。
Future<String> kotvClientId() async {
  if (_cached != null && _cached!.isNotEmpty) return _cached!;
  _cached = await KotvClientStore.clientId();
  return _cached!;
}
