/* 遥控页、管理页共用：请求引擎时带协议号和登录令牌；
   账号密码用引擎身份公钥加密发送，与引擎 internal/auth/seal.go 成对（X25519 + HKDF-SHA256 + AES-256-GCM）。
   普通 http 页面没有 WebCrypto，加密用随页附带的 noble.min.js。 */
(() => {
  'use strict';
  const PROTOCOL = '1';
  const TOKEN_KEY = 'kotv_web_token';
  const enc = new TextEncoder();
  const dec = new TextDecoder();
  let token = localStorage.getItem(TOKEN_KEY) || '';

  const b64 = (bytes) => btoa(String.fromCharCode(...bytes));
  const unb64 = (s) => Uint8Array.from(atob(s), (c) => c.charCodeAt(0));
  const concat = (a, b) => {
    const out = new Uint8Array(a.length + b.length);
    out.set(a);
    out.set(b, a.length);
    return out;
  };

  function setToken(t) {
    token = t || '';
    if (token) localStorage.setItem(TOKEN_KEY, token);
    else localStorage.removeItem(TOKEN_KEY);
  }

  // 带协议号与登录令牌请求引擎；登录失效（401）时清掉令牌，并通知页面回到登录。
  // 注意：静态遥控/管理页不要带 X-Kotv-Client-Platform: web。
  // 该头专给 Flutter Web：非本机时始终需登录；本机 127.0.0.1 静态页应免登。
  async function request(path, opts = {}) {
    const headers = Object.assign({ 'X-Kotv-Protocol': PROTOCOL }, opts.headers || {});
    if (token) headers.Authorization = 'Bearer ' + token;
    const res = await fetch(path, Object.assign({}, opts, { headers }));
    if (res.status === 401 && token) {
      setToken('');
      window.dispatchEvent(new Event('kotv-login-required'));
    }
    return res;
  }

  // 请求并解析 JSON；失败时抛出引擎给的原因。
  async function json(path, opts = {}) {
    const res = await request(path, opts);
    const data = await res.json().catch(() => ({}));
    if (!res.ok || data.ok === false) throw new Error(data.error || ('HTTP ' + res.status));
    return data;
  }

  // 用引擎身份公钥加密请求体；返回加密后的请求体和解开回复的函数。
  function seal(identity, path, body) {
    const { x25519, gcm, hkdf, sha256 } = window.kotvNoble;
    const enginePub = unb64(identity);
    const ephPriv = x25519.utils.randomPrivateKey();
    const ephPub = x25519.getPublicKey(ephPriv);
    const shared = x25519.getSharedSecret(ephPriv, enginePub);
    const keys = hkdf(sha256, shared, concat(ephPub, enginePub), enc.encode('kotv-seal-v1'), 64);
    const aad = enc.encode(path);
    const iv = crypto.getRandomValues(new Uint8Array(12));
    const data = gcm(keys.slice(0, 32), iv, aad).encrypt(enc.encode(JSON.stringify(body)));
    const open = (reply) => {
      const s = reply && reply.sealed;
      if (!s) throw new Error('后端没有加密回复');
      const plain = gcm(keys.slice(32), unb64(s.iv), aad).decrypt(unb64(s.data));
      return JSON.parse(dec.decode(plain));
    };
    return { body: { sealed: { key: b64(ephPub), iv: b64(iv), data: b64(data) } }, open };
  }

  // 带密码的请求：加密发送，解开加密回复。
  async function postSealed(path, body) {
    const health = await json('/api/v1/health');
    const sealed = seal(health.identity, path, body);
    const reply = await json(path, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(sealed.body),
    });
    return sealed.open(reply);
  }

  async function login(username, password) {
    const data = await postSealed('/api/v1/auth/login', { username, password });
    setToken(data.token);
    return data;
  }

  async function logout() {
    try {
      await json('/api/v1/auth/logout', { method: 'POST', body: '{}' });
    } catch (_) {}
    setToken('');
  }

  // 进入页面前的检查（遥控/管理台）：
  //   - 本机 127.0.0.1：免登录
  //   - 非本机：须管理员登录（adminOnly）；无远端鉴权时普通页仍 denied，管理面可先登录
  // 返回 'ok' / 'login' / 'denied' / 'notAdmin'
  async function check(adminOnly) {
    const st = await json('/api/v1/auth/status');
    if (st.loopback) return 'ok';
    if (!token) {
      if (adminOnly) return 'login';
      if (!st.remoteAccess) return 'denied';
      return 'login';
    }
    let me;
    try {
      me = await json('/api/v1/auth/me');
    } catch (_) {
      return 'login';
    }
    if (adminOnly && (!me.user || me.user.role !== 'admin')) {
      setToken('');
      return 'notAdmin';
    }
    return 'ok';
  }

  window.kotvAuth = { request, json, postSealed, login, logout, check, hasToken: () => !!token, clearToken: () => setToken('') };
})();
