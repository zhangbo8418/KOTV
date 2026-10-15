import '../api/kotv_api.dart';
import '../api/kotv_client_store.dart';

/// 历史/收藏等库操作共用的引擎 API（Web 空地址走页面 origin）。
Future<KotvApi> kotvEngineApi() async {
  return KotvApi(baseUrl: await KotvClientStore.effectiveEngineBaseUrl());
}
