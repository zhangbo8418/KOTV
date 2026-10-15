import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../util/kotv_app_dirs.dart';
import '../util/kotv_io.dart';

/// Flutter 客户端态：引擎地址、鉴权、窗口几何、clientId。
/// 桌面/安卓：`{kotvDataRoot}/ui/client.json`；Web：SharedPreferences。
class KotvClientStore {
  KotvClientStore._();

  static const _fileName = 'client.json';
  static const _webKey = 'kotv_client_json_v1';

  static KotvClientData? _cache;
  static Future<void>? _loadFuture;

  static Future<KotvClientData> load() {
    return _loadFuture ??= _doLoad().whenComplete(() {
      _loadFuture = null;
    });
  }

  static Future<KotvClientData> _doLoad() async {
    if (_cache != null) return _cache!;
    KotvClientData? data;
    if (kIsWeb) {
      data = await _loadWeb();
    } else {
      data = await _loadFile();
    }
    data ??= KotvClientData();
    if (data.isEmpty) {
      final migrated = await _migrateFromLegacyPrefs();
      if (migrated != null) {
        data = migrated;
        await _persist(data);
      }
    }
    _cache = data;
    return data;
  }

  static Future<void> _persist(KotvClientData data) async {
    _cache = data;
    if (kIsWeb) {
      await _saveWeb(data);
    } else {
      await _saveFile(data);
    }
  }

  static Future<void> update(void Function(KotvClientData d) fn) async {
    final d = await load();
    fn(d);
    await _persist(d);
  }

  // --- field helpers ---

  static Future<String> engineBaseUrl() async => (await load()).engineBaseUrl;
  static Future<String> engineBaseUrlDraft() async => (await load()).engineBaseUrlDraft;
  static Future<String> remoteUsername() async => (await load()).remoteUsername;
  static Future<String> authToken() async => (await load()).authToken;
  static Future<String> authUserId() async => (await load()).authUserId;
  static Future<String> clientId() async {
    final d = await load();
    if (d.clientId.isNotEmpty) return d.clientId;
    d.clientId = _newClientId();
    await _persist(d);
    return d.clientId;
  }

  static Future<void> setEngineBaseUrl(String v) => update((d) => d.engineBaseUrl = v.trim());
  static Future<void> setEngineBaseUrlDraft(String v) => update((d) => d.engineBaseUrlDraft = v.trim());
  static Future<void> setRemoteUsername(String v) => update((d) => d.remoteUsername = v.trim());
  static Future<void> setAuthToken(String v) => update((d) => d.authToken = v.trim());
  static Future<void> setAuthUserId(String v) => update((d) => d.authUserId = v.trim());
  static Future<void> clearAuth() => update((d) {
        d.authToken = '';
        d.authUserId = '';
      });

  static Future<void> clearEngine() => update((d) {
        d.engineBaseUrl = '';
        d.remoteUsername = '';
      });

  static Future<void> setWindowBounds({
    required double w,
    required double h,
    required double x,
    required double y,
  }) =>
      update((d) {
        d.windowW = w;
        d.windowH = h;
        d.windowX = x;
        d.windowY = y;
      });

  // --- IO ---

  static Future<File> _file() async {
    final dir = await kotvUiDir();
    return File('${dir.path}/$_fileName');
  }

  static Future<KotvClientData?> _loadFile() async {
    try {
      final f = await _file();
      if (!await f.exists()) return null;
      final raw = await f.readAsString();
      if (raw.trim().isEmpty) return null;
      return KotvClientData.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  static Future<void> _saveFile(KotvClientData data) async {
    final f = await _file();
    final dir = f.parent;
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsString(const JsonEncoder.withIndent('  ').convert(data.toJson()));
    if (await f.exists()) {
      await f.delete();
    }
    await tmp.rename(f.path);
  }

  static Future<KotvClientData?> _loadWeb() async {
    try {
      final p = await SharedPreferences.getInstance();
      final raw = p.getString(_webKey)?.trim() ?? '';
      if (raw.isEmpty) return null;
      return KotvClientData.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  static Future<void> _saveWeb(KotvClientData data) async {
    final p = await SharedPreferences.getInstance();
    await p.setString(_webKey, jsonEncode(data.toJson()));
  }

  /// 旧 SharedPreferences 键 → 一次迁入。
  static Future<KotvClientData?> _migrateFromLegacyPrefs() async {
    try {
      final p = await SharedPreferences.getInstance();
      final d = KotvClientData(
        engineBaseUrl: (p.getString('engine_base_url') ?? '').trim(),
        engineBaseUrlDraft: (p.getString('engine_base_url_draft') ?? '').trim(),
        remoteUsername: (p.getString('remote_username') ?? '').trim(),
        authToken: (p.getString('kotv_auth_token') ?? '').trim(),
        authUserId: (p.getString('kotv_auth_user_id') ?? '').trim(),
        clientId: (p.getString('kotv_client_id') ?? '').trim(),
        windowW: p.getDouble('window_w'),
        windowH: p.getDouble('window_h'),
        windowX: p.getDouble('window_x'),
        windowY: p.getDouble('window_y'),
      );
      if (d.isEmpty) return null;
      for (final k in [
        'engine_base_url',
        'engine_base_url_draft',
        'remote_username',
        'kotv_auth_token',
        'kotv_auth_user_id',
        'kotv_client_id',
        'window_w',
        'window_h',
        'window_x',
        'window_y',
      ]) {
        await p.remove(k);
      }
      return d;
    } catch (_) {
      return null;
    }
  }

  static String _newClientId() {
    final r = Random.secure();
    final bytes = List<int>.generate(16, (_) => r.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }
}

class KotvClientData {
  KotvClientData({
    this.engineBaseUrl = '',
    this.engineBaseUrlDraft = '',
    this.remoteUsername = '',
    this.authToken = '',
    this.authUserId = '',
    this.clientId = '',
    this.windowW,
    this.windowH,
    this.windowX,
    this.windowY,
  });

  String engineBaseUrl;
  String engineBaseUrlDraft;
  String remoteUsername;
  String authToken;
  String authUserId;
  String clientId;
  double? windowW;
  double? windowH;
  double? windowX;
  double? windowY;

  bool get isEmpty =>
      engineBaseUrl.isEmpty &&
      engineBaseUrlDraft.isEmpty &&
      remoteUsername.isEmpty &&
      authToken.isEmpty &&
      authUserId.isEmpty &&
      clientId.isEmpty &&
      windowW == null &&
      windowH == null &&
      windowX == null &&
      windowY == null;

  factory KotvClientData.fromJson(Map<String, dynamic> j) {
    final win = j['window'];
    Map<String, dynamic>? wmap;
    if (win is Map) wmap = Map<String, dynamic>.from(win);
    double? numOrNull(dynamic v) {
      if (v is num) return v.toDouble();
      return double.tryParse('$v');
    }

    return KotvClientData(
      engineBaseUrl: '${j['engineBaseUrl'] ?? ''}'.trim(),
      engineBaseUrlDraft: '${j['engineBaseUrlDraft'] ?? ''}'.trim(),
      remoteUsername: '${j['remoteUsername'] ?? ''}'.trim(),
      authToken: '${j['authToken'] ?? ''}'.trim(),
      authUserId: '${j['authUserId'] ?? ''}'.trim(),
      clientId: '${j['clientId'] ?? ''}'.trim(),
      windowW: numOrNull(wmap?['w']),
      windowH: numOrNull(wmap?['h']),
      windowX: numOrNull(wmap?['x']),
      windowY: numOrNull(wmap?['y']),
    );
  }

  Map<String, dynamic> toJson() => {
        'engineBaseUrl': engineBaseUrl,
        'engineBaseUrlDraft': engineBaseUrlDraft,
        'remoteUsername': remoteUsername,
        'authToken': authToken,
        'authUserId': authUserId,
        'clientId': clientId,
        if (windowW != null || windowH != null || windowX != null || windowY != null)
          'window': {
            if (windowW != null) 'w': windowW,
            if (windowH != null) 'h': windowH,
            if (windowX != null) 'x': windowX,
            if (windowY != null) 'y': windowY,
          },
      };
}
