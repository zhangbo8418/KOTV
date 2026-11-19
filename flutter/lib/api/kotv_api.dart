import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../player/kotv_platform.dart';
import '../util/kotv_io.dart' show kotvHostArch;
import 'kotv_auth_token.dart';
import 'kotv_client_id.dart';
import 'kotv_client_store.dart';
import 'kotv_engine_url.dart';
import 'kotv_seal.dart';

/// 每个请求都带的客户端信息：平台、架构、版本、协议号。远端后端按协议号决定是否服务。
Map<String, String> kotvClientHeaders() {
  final arch = kotvHostArch();
  return {
    'X-Kotv-Client-Platform': kotvHostPlatform(),
    if (arch.isNotEmpty) 'X-Kotv-Client-Arch': arch,
    'X-Kotv-Client-Version': kotvClientVersion,
    'X-Kotv-Protocol': '$kotvProtocolVersion',
  };
}

/// 健康检查响应的问题：不是 KOTV 后端，或协议号与本机不同。没问题返回空串。
String kotvEngineHealthProblem(Map<String, dynamic>? h) {
  if (h == null || h['ok'] != true || h['engine'] != 'kotv') return '该地址不是 KOTV 后端';
  if (h['protocol'] != kotvProtocolVersion) {
    final v = '${h['version'] ?? ''}'.trim();
    return '后端版本${v.isEmpty ? '过旧' : ' $v '}与本机 $kotvClientVersion 不兼容，请升级到相同版本';
  }
  return '';
}

/// 后端简介「平台 架构 · 版本」，如 android arm64 · 0.3.4。
String kotvEngineLabel(Map<String, dynamic> h) {
  final host = ['${h['platform'] ?? ''}', '${h['arch'] ?? ''}'].where((e) => e.isNotEmpty).join(' ');
  final version = '${h['version'] ?? ''}';
  return [host, version].where((e) => e.isNotEmpty).join(' · ');
}

/// 远端后端的身份与登录成功时记住的不一致。
class KotvEngineChangedException extends KotvApiException {
  KotvEngineChangedException()
      : super('后端身份与上次登录时不同，可能不是同一台主机。\n确认地址无误请在「连接后端」重新保存');
}

class KotvApi {
  KotvApi({String? baseUrl, String? clientId})
      : _baseUrl = baseUrl ?? kotvDefaultLocalEngineBaseUrl,
        _clientId = clientId?.trim() ?? '';

  String _baseUrl;
  String _clientId;
  final List<void Function()> _baseUrlListeners = [];

  String get baseUrl => _baseUrl;

  /// 业务地址变了才通知。界面套接字据此离开旧引擎。
  set baseUrl(String value) {
    if (value == _baseUrl) return;
    _baseUrl = value;
    final listeners = List<void Function()>.of(_baseUrlListeners);
    for (final fn in listeners) {
      fn();
    }
  }

  void Function() listenBaseUrl(void Function() onChange) {
    _baseUrlListeners.add(onChange);
    return () {
      _baseUrlListeners.remove(onChange);
    };
  }

  /// 确保已加载稳定 clientId（多前端 UI 路由用）。
  Future<String> _ensureClientId() async {
    if (_clientId.isNotEmpty) return _clientId;
    _clientId = await kotvClientId();
    return _clientId;
  }

  Uri _u(String path, [Map<String, String>? query]) =>
      Uri.parse('$baseUrl$path').replace(queryParameters: query);

  /// [withToken] 为 false 时不带登录令牌：确认后端身份前的探测请求不能把令牌交出去。
  Future<Map<String, String>> _headers([Map<String, String>? extra, bool withToken = true]) async {
    // 有 token 就带上（管理台/远端租户）；本机内容会话服务端仍只用 clientId。
    final token = withToken ? await kotvAuthToken() : '';
    final id = await _ensureClientId();
    final engineBase = kotvNormalizeEngineBaseUrl(baseUrl);
    return {
      if (id.isNotEmpty) 'X-Kotv-Client-Id': id,
      if (token.isNotEmpty) 'Authorization': 'Bearer $token',
      if (engineBase.isNotEmpty) 'X-Kotv-Engine-Base': engineBase,
      ...kotvClientHeaders(),
      ...?extra,
    };
  }

  Future<Map<String, dynamic>> _get(
    String path, [
    Map<String, String>? query,
    bool withToken = true,
  ]) async {
    final res = await http
        .get(_u(path, query), headers: await _headers(null, withToken))
        .timeout(const Duration(seconds: 120));
    return _decode(res);
  }

  Future<Map<String, dynamic>> _post(
    String path,
    Map<String, dynamic> body, {
    Duration timeout = const Duration(seconds: 120),
  }) async {
    final res = await http
        .post(
          _u(path),
          headers: await _headers({'Content-Type': 'application/json'}),
          body: jsonEncode(body),
        )
        .timeout(timeout);
    return _decode(res);
  }

  Map<String, dynamic> _decode(http.Response res) {
    final text = utf8.decode(res.bodyBytes);
    Map<String, dynamic> map;
    try {
      final decoded = jsonDecode(text);
      if (decoded is! Map<String, dynamic>) {
        throw FormatException('unexpected json');
      }
      map = decoded;
    } on FormatException {
      final snippet = text.trim();
      if (res.statusCode == 404 || snippet.toLowerCase().contains('404')) {
        throw KotvApiException('引擎接口不存在（404）。请重启/更新 kotv-engine 后再试。');
      }
      throw KotvApiException(
        snippet.isEmpty ? 'HTTP ${res.statusCode}' : '引擎返回异常: ${snippet.length > 120 ? '${snippet.substring(0, 120)}…' : snippet}',
      );
    }
    if (res.statusCode >= 400 || map['ok'] == false) {
      throw KotvApiException(map['error']?.toString() ?? 'HTTP ${res.statusCode}');
    }
    return map;
  }

  Future<Map<String, dynamic>> health() => _get('/api/v1/health', null, false);

  /// 引擎本机信息：`name` / `ip` / `ipv4` / `ipv6` / `publicIp` / `uuid`（见 `GET /device`）。
  Future<Map<String, dynamic>> getDevice() async {
    final res = await http
        .get(_u('/device'), headers: await _headers())
        .timeout(const Duration(seconds: 15));
    final text = utf8.decode(res.bodyBytes);
    try {
      final decoded = jsonDecode(text);
      if (decoded is Map<String, dynamic>) return decoded;
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    } catch (_) {}
    throw KotvApiException(text.trim().isEmpty ? 'HTTP ${res.statusCode}' : text.trim());
  }

  Future<Map<String, dynamic>> authStatus() => _get('/api/v1/auth/status', null, false);

  bool get _remoteEngine => !kIsWeb && !kotvIsLocalEngineBaseUrl(baseUrl);

  /// 校验后端并返回健康检查响应：连不上、不是 KOTV 后端、版本不兼容时抛错说明原因。
  /// [checkIdentity] 时远端后端还须与登录成功时记住的身份一致，否则抛 [KotvEngineChangedException]；
  /// 用户刚填写的地址不比对。
  Future<Map<String, dynamic>> verifyEngine({bool checkIdentity = true}) async {
    final Map<String, dynamic> h;
    try {
      h = await health().timeout(const Duration(seconds: 6));
    } on KotvApiException {
      throw KotvApiException('该地址不是 KOTV 后端');
    } catch (_) {
      throw KotvApiException('无法连接 $baseUrl');
    }
    final problem = kotvEngineHealthProblem(h);
    if (problem.isNotEmpty) throw KotvApiException(problem);
    if (checkIdentity && _remoteEngine) {
      final known = await KotvClientStore.engineKey(baseUrl);
      if (known.isNotEmpty && known != '${h['identity'] ?? ''}') throw KotvEngineChangedException();
    }
    return h;
  }

  /// 记住远端后端身份（登录成功或已登录时调用）。
  Future<void> rememberEngineIdentity(String identity) async {
    if (!_remoteEngine || identity.isEmpty) return;
    if (await KotvClientStore.engineKey(baseUrl) == identity) return;
    await KotvClientStore.setEngineKey(baseUrl, identity);
  }

  /// 带密码的请求：用后端身份公钥加密，回复也是加密的。返回回复和所用的身份公钥。
  Future<(Map<String, dynamic>, String)> _postSealed(String path, Map<String, dynamic> body) async {
    final identity = '${(await verifyEngine())['identity'] ?? ''}';
    final (request, seal) = await KotvSeal.seal(identity, path, body);
    return (await seal.open(await _post(path, request)), identity);
  }

  /// 登录并记住令牌、账号和后端身份；之后免登录，直到令牌或账号失效。
  Future<Map<String, dynamic>> login(String username, String password) async {
    final (data, identity) = await _postSealed('/api/v1/auth/login', {
      'username': username,
      'password': password,
    });
    final token = '${data['token'] ?? ''}';
    if (token.isNotEmpty) await kotvSetAuthToken(token);
    await KotvClientStore.update((d) => d.remoteUsername = username);
    await rememberEngineIdentity(identity);
    return data;
  }

  Future<Map<String, dynamic>> register(String username, String password) async =>
      (await _postSealed('/api/v1/auth/register', {'username': username, 'password': password})).$1;

  Future<Map<String, dynamic>> logout() async {
    try {
      final data = await _post('/api/v1/auth/logout', {});
      await kotvClearAuthToken();
      return data;
    } catch (_) {
      await kotvClearAuthToken();
      return {'ok': true};
    }
  }

  Future<Map<String, dynamic>> authMe() => _get('/api/v1/auth/me');

  Future<Map<String, dynamic>> changePassword({
    required String oldPassword,
    required String newPassword,
  }) async =>
      (await _postSealed('/api/v1/auth/password', {
        'oldPassword': oldPassword,
        'newPassword': newPassword,
      }))
          .$1;

  Future<Map<String, dynamic>> adminListUsers() => _get('/api/v1/admin/users');

  Future<Map<String, dynamic>> adminCreateUser({
    required String username,
    required String password,
    String role = 'user',
    String groupId = '',
  }) async =>
      (await _postSealed('/api/v1/admin/users', {
        'username': username,
        'password': password,
        'role': role,
        if (groupId.trim().isNotEmpty) 'groupId': groupId.trim(),
      }))
          .$1;

  Future<Map<String, dynamic>> adminListGroups() => _get('/api/v1/admin/groups');

  Future<Map<String, dynamic>> adminSetUserGroup(String id, String groupId) =>
      _post('/api/v1/admin/users/$id/group', {'groupId': groupId});

  Future<Map<String, dynamic>> adminSetUserRole(String id, String role) =>
      _post('/api/v1/admin/users/$id/role', {'role': role});

  Future<Map<String, dynamic>> adminApproveUser(String id) =>
      _post('/api/v1/admin/users/$id/approve', {});

  Future<Map<String, dynamic>> adminDeleteUser(String id) async {
    final res = await http
        .delete(_u('/api/v1/admin/users/$id'), headers: await _headers())
        .timeout(const Duration(seconds: 30));
    return _decode(res);
  }

  Future<Map<String, dynamic>> adminEnableUser(String id) =>
      _post('/api/v1/admin/users/$id/enable', {});

  Future<Map<String, dynamic>> adminDisableUser(String id) =>
      _post('/api/v1/admin/users/$id/disable', {});

  Future<Map<String, dynamic>> adminResetPassword(String id, String password) async =>
      (await _postSealed('/api/v1/admin/users/$id/password', {'password': password})).$1;

  Future<Map<String, dynamic>> adminSetSettings({
    bool? remoteAuth,
    bool? allowRegister,
    bool? requireApproval,
  }) {
    final body = <String, dynamic>{};
    if (remoteAuth != null) body['remoteAuth'] = remoteAuth;
    if (allowRegister != null) body['allowRegister'] = allowRegister;
    if (requireApproval != null) body['requireApproval'] = requireApproval;
    return _post('/api/v1/admin/settings', body);
  }

  Future<Map<String, dynamic>> sessionPing() => _post('/api/v1/session/ping', {});

  Future<Map<String, dynamic>> ackNotice(String id) =>
      _post('/api/v1/notice/ack', {'id': id});

  Future<Map<String, dynamic>> sessionLeave() async {
    try {
      return await _post('/api/v1/session/leave', {});
    } catch (_) {
      return {'ok': false};
    }
  }

  /// 本机优雅停引擎（会杀 Java/Python）；仅 loopback 可用。
  Future<Map<String, dynamic>> requestShutdown() =>
      _post('/api/v1/shutdown', const {}, timeout: const Duration(seconds: 3));

  Future<Map<String, dynamic>> getConfig() => _get('/api/v1/config');

  /// 换仓前先 soft 取消旧 Scope in-flight，避免卡满 120s 才切得动。
  Future<Map<String, dynamic>> loadConfig(String source) async {
    unawaited(cancelPending(hard: false, thunder: false));
    return _post('/api/v1/config', {'source': source});
  }

  /// 重新请求当前 http(s) 仓库，并重新检查 jar 与 js/py。
  Future<Map<String, dynamic>> refreshConfig() =>
      _post('/api/v1/config/refresh', {});

  /// 换站前先 soft 取消旧首页/分类 in-flight。
  Future<Map<String, dynamic>> setHome(String siteKey) async {
    unawaited(cancelPending(hard: false, thunder: false));
    return _post('/api/v1/sites', {'home': siteKey});
  }

  Future<Map<String, dynamic>> toggleSite({
    required String field,
    String key = '',
    bool? all,
  }) =>
      _post('/api/v1/sites', {
        'toggle': field,
        if (key.isNotEmpty) 'key': key,
        if (all != null) 'all': all,
      });

  Future<Map<String, dynamic>> home() => _get('/api/v1/home');

  Future<Map<String, dynamic>> category(
    String tid, {
    String pg = '1',
    String? site,
    Map<String, String>? extend,
  }) async {
    final params = <String, dynamic>{
      'tid': tid,
      'pg': pg,
      if (site != null && site.isNotEmpty) 'site': site,
    };
    if (extend == null || extend.isEmpty) {
      return _get('/api/v1/category', {
        'tid': tid,
        'pg': pg,
        if (site != null && site.isNotEmpty) 'site': site,
      });
    }
    return _post('/api/v1/category', {
      ...params,
      'extend': extend,
    });
  }

  Future<Map<String, dynamic>> detail({required String id, String? site}) =>
      _get('/api/v1/detail', {
        'id': id,
        if (site != null && site.isNotEmpty) 'site': site,
      });

  Future<Map<String, dynamic>> detailExpand({
    required String id,
    String? site,
    List<Map<String, dynamic>>? flags,
  }) =>
      _post('/api/v1/detail/expand', {
        'id': id,
        if (site != null && site.isNotEmpty) 'site': site,
        if (flags != null) 'flags': flags,
      });

  Future<Map<String, dynamic>> btProgress() => _get('/api/v1/bt/progress');

  Future<Map<String, dynamic>> downloadList() =>
      _get('/api/v1/download', {'action': 'list'});

  Future<Map<String, dynamic>> downloadEnqueue(Map<String, dynamic> body) =>
      _post('/api/v1/download', {'action': 'enqueue', ...body});

  Future<Map<String, dynamic>> downloadCancel(String id) =>
      _post('/api/v1/download', {'action': 'cancel', 'id': id});

  Future<Map<String, dynamic>> downloadPause(String id) =>
      _post('/api/v1/download', {'action': 'pause', 'id': id});

  Future<Map<String, dynamic>> downloadResume(String id) =>
      _post('/api/v1/download', {'action': 'resume', 'id': id});

  Future<Map<String, dynamic>> downloadRemove(String id,
          {bool deleteFile = false}) =>
      _post('/api/v1/download', {
        'action': 'remove',
        'id': id,
        'deleteFile': deleteFile,
      });

  /// 列出引擎本机目录；path 空则返回浏览根。
  Future<Map<String, dynamic>> fsList([String path = '']) =>
      _get('/api/v1/fs', {
        if (path.trim().isNotEmpty) 'path': path.trim(),
      });

  Future<Map<String, dynamic>> search(
    String keyword, {
    List<String>? sites,
    bool exact = false,
    String excludeSite = '',
    String excludeId = '',
    List<Map<String, String>>? exclude,
  }) =>
      _post('/api/v1/search', {
        'keyword': keyword,
        if (sites != null && sites.isNotEmpty) 'sites': sites,
        if (exact) 'exact': true,
        if (excludeSite.isNotEmpty) 'excludeSite': excludeSite,
        if (excludeId.isNotEmpty) 'excludeId': excludeId,
        if (exclude != null && exclude.isNotEmpty) 'exclude': exclude,
      });

  Future<Map<String, dynamic>> play({
    String url = '',
    int index = -1,
    String? site,
    String? id,
    String? flag,
    int qual = 0,
  }) =>
      _post('/api/v1/play', {
        'url': url,
        if (index >= 0) 'index': index,
        if (site != null) 'site': site,
        if (id != null) 'id': id,
        if (flag != null) 'flag': flag,
        'qual': qual,
      });

  /// 引擎拉取并解析一个弹幕源（视频页、弹幕地址或引擎本机弹幕文件）→ `{items:[...]}`。
  /// [duration] 片长：视频页按 60 秒分段拉取时用来定段数，未知传 0。
  Future<Map<String, dynamic>> danmakuLoad(String url, {Duration duration = Duration.zero}) =>
      _get('/api/v1/danmaku', {
        'action': 'load',
        'url': url,
        if (duration > Duration.zero) 'duration': '${duration.inMilliseconds}',
      });

  /// 按片名/集名调弹幕搜索接口 → `{sources:[{name,url}]}`。
  Future<Map<String, dynamic>> danmakuSearch({required String name, required String episode}) =>
      _post('/api/v1/danmaku?action=search', {'name': name, 'episode': episode});

  /// 起播时由引擎决定弹幕源：片源弹幕加自动搜到的 → `{sources:[...], selected}`。
  Future<Map<String, dynamic>> danmakuAuto({
    required String site,
    required String name,
    required String episode,
    required List<Map<String, String>> sources,
  }) =>
      _post('/api/v1/danmaku?action=auto', {
        'site': site,
        'name': name,
        'episode': episode,
        'sources': sources,
      });

  Future<Map<String, dynamic>> remotePoll() => _get('/api/v1/remote/poll');

  Future<Map<String, dynamic>> setMedia(Map<String, String> state) =>
      _post('/api/v1/media', Map<String, dynamic>.from(state));

  Future<Map<String, dynamic>> listRepos() => _get('/api/v1/repos');

  Future<Map<String, dynamic>> deleteRepo(String url) async {
    final res = await http
        .delete(_u('/api/v1/repos', {'url': url}), headers: await _headers())
        .timeout(const Duration(seconds: 30));
    return _decode(res);
  }

  Future<Map<String, dynamic>> editRepo({
    required String oldUrl,
    required String url,
    String name = '',
  }) =>
      _post('/api/v1/repos', {
        'action': 'edit',
        'oldUrl': oldUrl,
        'url': url,
        'name': name,
      });

  Future<Map<String, dynamic>> getSettings() => _get('/api/v1/settings');

  Future<Map<String, dynamic>> setSetting(String key, String value) =>
      _post('/api/v1/settings', {'key': key, 'value': value});

  Future<Map<String, dynamic>> setSettings(Map<String, String> settings) =>
      _post('/api/v1/settings', {'settings': settings});

  Future<Map<String, dynamic>> liveSources() => _get('/api/v1/live');

  Future<Map<String, dynamic>> deleteLive(String url) =>
      _post('/api/v1/live', {'action': 'delete', 'url': url});

  Future<Map<String, dynamic>> editLive({
    required String oldUrl,
    required String url,
    String name = '',
  }) =>
      _post('/api/v1/live', {
        'action': 'edit',
        'oldUrl': oldUrl,
        'url': url,
        'name': name,
      });

  Future<Map<String, dynamic>> liveLoad({
    int index = 0,
    String url = '',
    bool force = false,
  }) =>
      _post('/api/v1/live', {
        'action': 'load',
        'index': index,
        if (url.isNotEmpty) 'url': url,
        if (force) 'force': true,
      });

  Future<Map<String, dynamic>> livePlay({
    required int group,
    required int channel,
    int line = 0,
  }) =>
      _post('/api/v1/live', {
        'action': 'play',
        'group': group,
        'channel': channel,
        'line': line,
      });

  Future<Map<String, dynamic>> liveUnlock({required int group, required String password}) =>
      _post('/api/v1/live', {
        'action': 'unlock',
        'group': group,
        'password': password,
      });

  Future<Map<String, dynamic>> liveEpg({required int group, required int channel}) =>
      _post('/api/v1/live', {
        'action': 'epg',
        'group': group,
        'channel': channel,
      });

  Future<Map<String, dynamic>> liveCatchup({
    required int group,
    required int channel,
    required int day,
    required int prog,
  }) =>
      _post('/api/v1/live', {
        'action': 'catchup',
        'group': group,
        'channel': channel,
        'day': day,
        'prog': prog,
      });

  Future<Map<String, dynamic>> playerStatus() => _get('/api/v1/player');

  Future<Map<String, dynamic>> tools(String action, [Map<String, dynamic>? params]) =>
      _post('/api/v1/tools', {
        'action': action,
        if (params != null && params.isNotEmpty) 'params': params,
      });

  Future<Map<String, dynamic>> assrtSearch(String q, {int limit = 15}) =>
      tools('assrtSearch', {'q': q, 'limit': limit});

  Future<Map<String, dynamic>> assrtDetail(int id) =>
      tools('assrtDetail', {'id': id});

  Future<Map<String, dynamic>> assrtDownload({
    required String url,
    String name = '',
    String size = '',
  }) =>
      tools('assrtDownload', {'url': url, 'name': name, 'size': size});

  /// 界面套接字。浏览器不能带自定义头，身份放在查询参数里。
  Future<({String url, Map<String, String> headers})> uiSocket() async {
    final id = await _ensureClientId();
    final headers = await _headers();
    final base = Uri.parse(baseUrl);
    final query = <String, String>{
      'role': 'ui',
      'clientId': id,
      'platform': kotvHostPlatform(),
    };
    if (kIsWeb) {
      final token = headers['Authorization'] ?? '';
      const prefix = 'Bearer ';
      if (token.startsWith(prefix) && token.length > prefix.length) {
        query['token'] = token.substring(prefix.length).trim();
      }
    }
    final url = base.replace(
      scheme: base.scheme == 'https' ? 'wss' : 'ws',
      path: '/ui',
      queryParameters: query,
    ).toString();
    return (url: url, headers: kIsWeb ? const <String, String>{} : headers);
  }

  /// 站点 action（Market 下载等）：vod 带 action 字段时调用。
  Future<Map<String, dynamic>> siteAction({required String site, required String action}) =>
      _post('/api/v1/action', {'site': site, 'action': action});

  /// 片库列表：history / keep / liveKeep（SQLite，按登录 owner 分桶）。
  Future<Map<String, dynamic>> library(String type, {int limit = 200}) =>
      _get('/library', {'type': type, 'limit': '$limit'});

  Future<Map<String, dynamic>> libraryAction(Map<String, dynamic> body) =>
      _post('/library', body, timeout: const Duration(seconds: 30));

  /// 打断进行中的详情/分类等爬虫请求。
  /// [hard] false：软取消当前 Scope（不杀唯一 JVM）；换集/离开/搜索默认 soft。
  /// true：显式卡死恢复（清本租户态；仅 bridge 不健康时才 HardRestart）。不自动升档。
  /// [thunder] 停磁力 Fetch / 专用源；默认 false（离开详情不停；磁力起播显式 true）。
  Future<Map<String, dynamic>> cancelPending({bool hard = false, bool thunder = false}) async {
    try {
      return await _post(
        '/api/v1/cancel',
        {'hard': hard, 'thunder': thunder},
        timeout: const Duration(seconds: 5),
      );
    } catch (_) {
      return {'ok': false};
    }
  }
}

class KotvApiException implements Exception {
  KotvApiException(this.message);
  final String message;
  @override
  String toString() => message;
}
