(() => {
  'use strict';
  const $ = (s) => document.querySelector(s);
  let token = localStorage.getItem('kotv_admin_token') || '';

  function toast(msg) {
    const el = $('#toast');
    el.textContent = msg;
    el.classList.add('show');
    setTimeout(() => el.classList.remove('show'), 1800);
  }

  async function api(path, opts = {}) {
    const headers = Object.assign({ 'Content-Type': 'application/json' }, opts.headers || {});
    if (token) headers.Authorization = 'Bearer ' + token;
    const res = await fetch(path, Object.assign({}, opts, { headers }));
    const data = await res.json().catch(() => ({}));
    if (res.status === 401 || res.status === 403) {
      const authPublic = path.indexOf('/api/v1/auth/login') === 0 || path.indexOf('/api/v1/auth/register') === 0;
      if (!authPublic) clearSession();
      throw new Error(data.error || (res.status === 403 ? '需要管理员' : '需要登录'));
    }
    if (!res.ok || data.ok === false) throw new Error(data.error || ('HTTP ' + res.status));
    return data;
  }

  function clearSession() {
    token = '';
    localStorage.removeItem('kotv_admin_token');
    showLoggedIn(false);
  }

  function showLoggedIn(on) {
    $('#login_box').classList.toggle('hidden', on);
    $('#panel').classList.toggle('hidden', !on);
  }

  async function refresh() {
    const data = await api('/api/v1/admin/users');
    $('#opt_remote').checked = !!data.remoteAuth;
    $('#opt_register').checked = !!data.allowRegister;
    const tb = $('#user_rows');
    tb.innerHTML = '';
    (data.users || []).forEach((u) => {
      const tr = document.createElement('tr');
      tr.innerHTML = `<td>${esc(u.username)}</td><td>${esc(u.role)}</td><td>${u.enabled ? '启用' : '禁用'}</td><td class="row"></td>`;
      const actions = tr.querySelector('td:last-child');
      const btnEn = document.createElement('button');
      btnEn.className = 'btn ghost';
      btnEn.textContent = u.enabled ? '禁用' : '启用';
      btnEn.onclick = async () => {
        try {
          await api('/api/v1/admin/users/' + u.id + '/' + (u.enabled ? 'disable' : 'enable'), { method: 'POST', body: '{}' });
          refresh();
        } catch (e) { toast(e.message); }
      };
      const btnPw = document.createElement('button');
      btnPw.className = 'btn ghost';
      btnPw.textContent = '重置密码';
      btnPw.onclick = async () => {
        const p = prompt('新密码');
        if (!p) return;
        try {
          await api('/api/v1/admin/users/' + u.id + '/password', { method: 'POST', body: JSON.stringify({ password: p }) });
          toast('已重置');
        } catch (e) { toast(e.message); }
      };
      const btnDel = document.createElement('button');
      btnDel.className = 'btn danger';
      btnDel.textContent = '删除';
      btnDel.onclick = async () => {
        if (!confirm('删除 ' + u.username + '？')) return;
        try {
          await api('/api/v1/admin/users/' + u.id, { method: 'DELETE' });
          refresh();
        } catch (e) { toast(e.message); }
      };
      actions.append(btnEn, btnPw, btnDel);
      tb.appendChild(tr);
    });
  }

  function esc(s) {
    return String(s || '').replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;');
  }

  async function enterAdmin(tok, user) {
    if (!user || user.role !== 'admin') {
      clearSession();
      throw new Error('需要管理员账号');
    }
    token = tok;
    localStorage.setItem('kotv_admin_token', token);
    showLoggedIn(true);
    await refresh();
  }

  $('#btn_login').onclick = async () => {
    try {
      const data = await api('/api/v1/auth/login', {
        method: 'POST',
        body: JSON.stringify({ username: $('#login_user').value.trim(), password: $('#login_pass').value }),
      });
      await enterAdmin(data.token, data.user);
      if (data.user && data.user.mustChangePassword) {
        toast('请尽快修改默认密码');
      }
    } catch (e) { toast(e.message); }
  };

  $('#login_pass').addEventListener('keydown', (ev) => {
    if (ev.key === 'Enter') $('#btn_login').click();
  });

  $('#btn_logout').onclick = async () => {
    try { await api('/api/v1/auth/logout', { method: 'POST', body: '{}' }); } catch (_) {}
    clearSession();
  };

  $('#btn_save_opts').onclick = async () => {
    try {
      await api('/api/v1/admin/settings', {
        method: 'POST',
        body: JSON.stringify({
          remoteAuth: $('#opt_remote').checked,
          allowRegister: $('#opt_register').checked,
        }),
      });
      toast('已保存');
    } catch (e) { toast(e.message); }
  };

  $('#btn_create').onclick = async () => {
    try {
      await api('/api/v1/admin/users', {
        method: 'POST',
        body: JSON.stringify({
          username: $('#new_user').value.trim(),
          password: $('#new_pass').value,
          role: $('#new_role').value,
        }),
      });
      $('#new_user').value = '';
      $('#new_pass').value = '';
      await refresh();
      toast('已创建');
    } catch (e) { toast(e.message); }
  };

  (async () => {
    if (!token) {
      showLoggedIn(false);
      return;
    }
    try {
      const me = await api('/api/v1/auth/me');
      await enterAdmin(token, me.user);
    } catch (_) {
      clearSession();
    }
  })();
})();
