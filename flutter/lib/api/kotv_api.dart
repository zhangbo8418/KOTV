import 'dart:convert';

import 'package:http/http.dart' as http;

import 'kotv_auth_token.dart';
import 'kotv_client_id.dart';

class KotvApi {
  KotvApi({String? baseUrl, String? clientId})
      : baseUrl = baseUrl ?? 'http://127.0.0.1:9978',
        _clientId = clientId?.trim() ?? '';

  String baseUrl;
  String _clientId;

  /// 确保已加载稳定 clientId（多前端 UI 路由用）。
  Future<String> ensureClientId() async {
    if (_clientId.isNotEmpty) return _clientId;
    _clientId = await kotvClientId();
    return _clientId;
  }

  Uri _u(String path, [Map<String, String>? query]) =>
      Uri.parse('$baseUrl$path').replace(queryParameters: query);

  Future<Map<String, String>> _headers([Map<String, String>? extra]) async {
    final token = await kotvAuthToken();
    // 已登录：只用 Bearer（服务端用 userId 隔离）；未登录本机才带 clientId。
    final id = token.isEmpty ? await ensureClientId() : '';
    return {
      if (id.isNotEmpty) 'X-Kotv-Client-Id': id,
      if (token.isNotEmpty) 'Authorization': 'Bearer $token',
      ...?extra,
    };
  }

  Future<Map<String, dynamic>> _get(String path, [Map<String, String>? query]) async {
    final res = await http
        .get(_u(path, query), headers: await _headers())
        .timeout(const Duration(seconds: 120));
    return _decode(res);
  }

  Future<Map<String, dynamic>> _post(String path, Map<String, dynamic> body) async {
    final res = await http
        .post(
          _u(path),
          headers: await _headers({'Content-Type': 'application/json'}),
          body: jsonEncode(body),
        )
        .timeout(const Duration(seconds: 120));
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

  Future<Map<String, dynamic>> health() => _get('/api/v1/health');

  Future<Map<String, dynamic>> authStatus() => _get('/api/v1/auth/status');

  Future<Map<String, dynamic>> login(String username, String password) async {
    final data = await _post('/api/v1/auth/login', {
      'username': username,
      'password': password,
    });
    final token = '${data['token'] ?? ''}';
    if (token.isNotEmpty) await kotvSetAuthToken(token);
    return data;
  }

  Future<Map<String, dynamic>> register(String username, String password) =>
      _post('/api/v1/auth/register', {'username': username, 'password': password});

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

  Future<Map<String, dynamic>> sessionPing() => _post('/api/v1/session/ping', {});

  Future<Map<String, dynamic>> sessionLeave() async {
    try {
      return await _post('/api/v1/session/leave', {});
    } catch (_) {
      return {'ok': false};
    }
  }

  /// 本机优雅停引擎（会杀 Java/Python）；仅 loopback 可用。
  Future<Map<String, dynamic>> requestShutdown() async {
    final res = await http
        .post(
          _u('/api/v1/shutdown'),
          headers: await _headers({'Content-Type': 'application/json'}),
          body: '{}',
        )
        .timeout(const Duration(seconds: 3));
    return _decode(res);
  }

  Future<Map<String, dynamic>> getConfig() => _get('/api/v1/config');

  Future<Map<String, dynamic>> loadConfig(String source) =>
      _post('/api/v1/config', {'source': source});

  Future<Map<String, dynamic>> setHome(String siteKey) =>
      _post('/api/v1/sites', {'home': siteKey});

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

  Future<Map<String, dynamic>> category(String tid, {String pg = '1', Map<String, String>? extend}) async {
    if (extend == null || extend.isEmpty) {
      return _get('/api/v1/category', {'tid': tid, 'pg': pg});
    }
    return _post('/api/v1/category', {
      'tid': tid,
      'pg': pg,
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

  Future<Map<String, dynamic>> search(String keyword) =>
      _post('/api/v1/search', {'keyword': keyword});

  Future<Map<String, dynamic>> play({
    required String url,
    String? site,
    String? id,
    String? flag,
    int qual = 0,
  }) =>
      _post('/api/v1/play', {
        'url': url,
        if (site != null) 'site': site,
        if (id != null) 'id': id,
        if (flag != null) 'flag': flag,
        'qual': qual,
      });

  Future<Map<String, dynamic>> remotePoll() => _get('/api/v1/remote/poll');

  Future<Map<String, dynamic>> setMedia(Map<String, String> state) =>
      _post('/api/v1/media', Map<String, dynamic>.from(state));

  Future<Map<String, dynamic>> getMedia() => _get('/api/v1/media');

  Future<Map<String, dynamic>> listRepos() => _get('/api/v1/repos');

  Future<Map<String, dynamic>> deleteRepo(String url) async {
    final res = await http
        .delete(_u('/api/v1/repos', {'url': url}), headers: await _headers())
        .timeout(const Duration(seconds: 30));
    return _decode(res);
  }

  Future<Map<String, dynamic>> getSettings() => _get('/api/v1/settings');

  Future<Map<String, dynamic>> setSetting(String key, String value) =>
      _post('/api/v1/settings', {'key': key, 'value': value});

  Future<Map<String, dynamic>> setSettings(Map<String, String> settings) =>
      _post('/api/v1/settings', {'settings': settings});

  Future<Map<String, dynamic>> liveSources() => _get('/api/v1/live');

  Future<Map<String, dynamic>> liveLoad({int index = 0, String url = ''}) =>
      _post('/api/v1/live', {
        'action': 'load',
        'index': index,
        if (url.isNotEmpty) 'url': url,
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

  Future<Map<String, dynamic>> playerExternal({
    required String url,
    required String player,
  }) =>
      _post('/api/v1/player', {
        'action': 'external',
        'url': url,
        'player': player,
      });

  Future<Map<String, dynamic>> tools(String action, [Map<String, dynamic>? params]) =>
      _post('/api/v1/tools', {
        'action': action,
        if (params != null && params.isNotEmpty) 'params': params,
      });

  /// 轮询爬虫 UiBridge / Util.notify 声明式弹窗消息。
  Future<Map<String, dynamic>> uiPoll() => _get('/api/v1/ui/poll');

  Future<Map<String, dynamic>> uiReply({
    required String id,
    required String action,
    Map<String, String>? values,
  }) =>
      _post('/api/v1/ui/reply', {
        'id': id,
        'action': action,
        if (values != null && values.isNotEmpty) 'values': values,
      });

  /// 打断进行中的详情/分类等爬虫请求。
  /// [hard] 硬杀所属 JVM/Py/JS；换集默认 false（软取消）。
  /// [thunder] 停磁力 Fetch（会显示「已取消」）；非磁力起播应 false。
  Future<Map<String, dynamic>> cancelPending({bool hard = false, bool thunder = true}) async {
    try {
      final res = await http
          .post(
            _u('/api/v1/cancel'),
            headers: await _headers({'Content-Type': 'application/json'}),
            body: jsonEncode({'hard': hard, 'thunder': thunder}),
          )
          .timeout(const Duration(seconds: 5));
      return _decode(res);
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
