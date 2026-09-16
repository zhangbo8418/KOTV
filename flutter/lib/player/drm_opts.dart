import 'dart:convert';

import 'mpv_opts.dart';

/// 本地 ClearKey（非 HTTP license）→ lavf `decryption_key` 十六进制。
bool kotvIsLocalClearKey(Map<String, dynamic>? drm) {
  if (drm == null || drm.isEmpty) return false;
  final type = '${drm['type'] ?? ''}'.trim().toLowerCase();
  if (!type.contains('clearkey')) return false;
  final key = '${drm['key'] ?? ''}'.trim();
  if (key.isEmpty) return false;
  if (key.startsWith('http://') || key.startsWith('https://')) return false;
  return kotvClearKeyHex(drm) != null;
}

/// 从 kid:key / JWK 取出首个密钥的 hex（供 ffmpeg/mpv demuxer-lavf-o）。
String? kotvClearKeyHex(Map<String, dynamic>? drm) {
  if (drm == null) return null;
  final raw = '${drm['key'] ?? ''}'.trim();
  if (raw.isEmpty) return null;
  if (raw.startsWith('{')) {
    try {
      final j = jsonDecode(raw);
      if (j is Map) {
        final keys = j['keys'];
        if (keys is List && keys.isNotEmpty) {
          final first = keys.first;
          if (first is Map) {
            final k = '${first['k'] ?? ''}'.trim();
            final hex = _b64urlToHex(k);
            if (hex != null && hex.isNotEmpty) return hex;
          }
        }
      }
    } catch (_) {}
  }
  // kid:key[,kid:key…]
  final cleaned = raw.replaceAll('"', '').replaceAll('{', '').replaceAll('}', '');
  for (final part in cleaned.split(',')) {
    final kv = part.trim().split(':');
    if (kv.length < 2) continue;
    final kHex = kv.sublist(1).join(':').trim();
    if (RegExp(r'^[0-9a-fA-F]+$').hasMatch(kHex) && kHex.length >= 32) {
      return kHex.toLowerCase();
    }
  }
  return null;
}

String kotvLavfOWithClearKey(String? keyHex) {
  final base = kotvDemuxerLavfO;
  final hex = (keyHex ?? '').trim();
  if (hex.isEmpty) return base;
  return '$base,decryption_key=$hex';
}

String? _b64urlToHex(String raw) {
  var s = raw.trim().replaceAll('-', '+').replaceAll('_', '/');
  while (s.length % 4 != 0) {
    s += '=';
  }
  try {
    final bytes = base64Decode(s);
    if (bytes.isEmpty) return null;
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  } catch (_) {
    return null;
  }
}
