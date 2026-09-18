/* KO影视 Web：hls.js 胶水（Safari 原生 HLS，其它浏览器走 hls.js）+ ClearKey EME */
(function (global) {
  'use strict';

  function destroy(video) {
    if (!video) return;
    try {
      if (video._kotvHls) {
        video._kotvHls.destroy();
        video._kotvHls = null;
      }
    } catch (_) {}
    try {
      if (video._kotvMediaKeysCleanup) {
        video._kotvMediaKeysCleanup();
        video._kotvMediaKeysCleanup = null;
      }
    } catch (_) {}
    try {
      video.removeAttribute('src');
      video.load();
    } catch (_) {}
  }

  function b64urlToU8(s) {
    s = String(s || '').replace(/-/g, '+').replace(/_/g, '/');
    while (s.length % 4) s += '=';
    var bin = atob(s);
    var out = new Uint8Array(bin.length);
    for (var i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
    return out;
  }

  function hexToU8(hex) {
    hex = String(hex || '').replace(/\s+/g, '');
    if (hex.length % 2) return null;
    var out = new Uint8Array(hex.length / 2);
    for (var i = 0; i < out.length; i++) {
      out[i] = parseInt(hex.substr(i * 2, 2), 16);
    }
    return out;
  }

  /** 解析 ClearKey：JWK JSON / kid:key hex。返回 { kids:[{kid,k}] } 或 null。 */
  function parseClearKey(raw) {
    raw = String(raw || '').trim();
    if (!raw) return null;
    if (raw.charAt(0) === '{') {
      try {
        var j = JSON.parse(raw);
        if (j && Array.isArray(j.keys) && j.keys.length) {
          return {
            keys: j.keys.map(function (e) {
              return { kid: e.kid, k: e.k };
            }),
          };
        }
      } catch (_) {}
    }
    var cleaned = raw.replace(/["{}]/g, '');
    var parts = cleaned.split(',');
    var keys = [];
    for (var i = 0; i < parts.length; i++) {
      var kv = parts[i].trim().split(':');
      if (kv.length !== 2) continue;
      var kidB = hexToU8(kv[0].trim());
      var kB = hexToU8(kv[1].trim());
      if (!kidB || !kB) continue;
      keys.push({
        kid: btoa(String.fromCharCode.apply(null, kidB)).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, ''),
        k: btoa(String.fromCharCode.apply(null, kB)).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, ''),
      });
    }
    return keys.length ? { keys: keys } : null;
  }

  function setupClearKey(video, drm) {
    if (!video || !drm || !global.navigator || !navigator.requestMediaKeySystemAccess) {
      return Promise.resolve(false);
    }
    var typ = String(drm.type || drm.Type || '').toLowerCase();
    if (typ.indexOf('clearkey') < 0) return Promise.resolve(false);
    var keyRaw = String(drm.key || drm.Key || '').trim();
    if (!keyRaw) return Promise.resolve(false);
    // 在线 license URL：先拉再装（与桌面 PrepareForDesktop 同思路）。
    var loadKeys = Promise.resolve(keyRaw);
    if (/^https?:\/\//i.test(keyRaw)) {
      loadKeys = fetch(keyRaw).then(function (r) {
        if (!r.ok) throw new Error('license HTTP ' + r.status);
        return r.text();
      });
    }
    return loadKeys.then(function (body) {
      var parsed = parseClearKey(body);
      if (!parsed) throw new Error('ClearKey 无可用密钥');
      var config = [{
        initDataTypes: ['cenc', 'webm', 'keyids'],
        audioCapabilities: [{ contentType: 'audio/mp4; codecs="mp4a.40.2"' }],
        videoCapabilities: [{ contentType: 'video/mp4; codecs="avc1.42E01E"' }],
      }];
      return navigator.requestMediaKeySystemAccess('org.w3.clearkey', config).then(function (access) {
        return access.createMediaKeys();
      }).then(function (keys) {
        return video.setMediaKeys(keys).then(function () {
          return keys;
        });
      }).then(function (keys) {
        var onEncrypted = function (ev) {
          try {
            var session = keys.createSession();
            var license = JSON.stringify({
              keys: parsed.keys.map(function (e) {
                return { kty: 'oct', kid: e.kid, k: e.k };
              }),
              type: 'temporary',
            });
            session.generateRequest(ev.initDataType, ev.initData).then(function () {
              return session.update(new TextEncoder().encode(license));
            }).catch(function (err) {
              console.warn('kotv ClearKey session', err);
            });
          } catch (err) {
            console.warn('kotv ClearKey encrypted', err);
          }
        };
        video.addEventListener('encrypted', onEncrypted);
        video._kotvMediaKeysCleanup = function () {
          try { video.removeEventListener('encrypted', onEncrypted); } catch (_) {}
          try { video.setMediaKeys(null); } catch (_) {}
        };
        return true;
      });
    }).catch(function (err) {
      console.warn('kotv ClearKey EME', err);
      return false;
    });
  }

  function attach(video, url, headers, drm) {
    destroy(video);
    if (!video || !url) return 'none';

    // 异步装 ClearKey；失败不阻断起播（无密钥片源仍可试播）。
    try { setupClearKey(video, drm); } catch (_) {}

    var HlsCtor = global.Hls;
    if (HlsCtor && typeof HlsCtor.isSupported === 'function' && HlsCtor.isSupported()) {
      var hls = new HlsCtor({
        enableWorker: true,
        lowLatencyMode: false,
        xhrSetup: function (xhr) {
          if (!headers) return;
          try {
            Object.keys(headers).forEach(function (k) {
              try {
                xhr.setRequestHeader(k, headers[k]);
              } catch (_) {}
            });
          } catch (_) {}
        },
      });
      hls.loadSource(url);
      hls.attachMedia(video);
      video._kotvHls = hls;
      return 'hls';
    }

    // Safari / iOS：原生 HLS
    if (video.canPlayType && video.canPlayType('application/vnd.apple.mpegurl')) {
      video.src = url;
      return 'native';
    }

    // 非 HLS 或无法探测：直链
    video.src = url;
    return 'html';
  }

  global.kotvHls = {
    ready: !!(global.Hls),
    attach: attach,
    destroy: destroy,
    setupClearKey: setupClearKey,
  };
})(typeof window !== 'undefined' ? window : globalThis);
