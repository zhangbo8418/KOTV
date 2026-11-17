(() => {
  'use strict';
  const $ = (s) => document.querySelector(s);
  const api = (path, opts) => kotvAuth.json(path, opts);
  const post = (path, body) => api(path, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body || {}) });
  let repoPanel = null;

  function toast(msg) {
    const el = $('#toast');
    el.textContent = msg;
    el.classList.add('show');
    setTimeout(() => el.classList.remove('show'), 1800);
  }

  function esc(s) {
    return String(s || '').replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
  }

  function showPanel(on, hint) {
    $('#login_box').classList.toggle('hidden', on);
    $('#panel').classList.toggle('hidden', !on);
    $('#login_form').classList.toggle('hidden', !!hint);
    $('#login_hint').textContent = hint || '远端管理需要管理员账号';
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
          await post('/api/v1/admin/users/' + u.id + '/' + (u.enabled ? 'disable' : 'enable'));
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
          await kotvAuth.postSealed('/api/v1/admin/users/' + u.id + '/password', { password: p });
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

  // 本机直接进入；远端须以管理员登录。
  async function enter() {
    let state;
    try {
      state = await kotvAuth.check(true);
    } catch (_) {
      return showPanel(false, '无法连接主机');
    }
    if (state === 'denied') return showPanel(false, '主机未开放远端访问，请在主机上打开远端鉴权');
    if (state !== 'ok') {
      showPanel(false);
      if (state === 'notAdmin') $('#login_hint').textContent = '当前账号不是管理员，请换管理员账号登录';
      return;
    }
    $('#btn_logout').classList.toggle('hidden', !kotvAuth.hasToken());
    showPanel(true);
    try {
      await refresh();
    } catch (e) {
      toast(e.message);
    }
    if (!repoPanel && window.kotvRepos) {
      repoPanel = kotvRepos.bindPanel({
        kindSelect: $('#repo_kind'),
        urlInput: $('#repo_url'),
        nameInput: $('#repo_name'),
        listEl: $('#admin_repo_list'),
        addBtn: $('#btn_repo_add'),
        refreshBtn: $('#btn_repo_refresh'),
        onToast: toast,
      });
    }
    if (repoPanel) repoPanel.refresh();
  }

  async function login() {
    try {
      const data = await kotvAuth.login($('#login_user').value.trim(), $('#login_pass').value);
      $('#login_pass').value = '';
      if (data.user && data.user.mustChangePassword) toast('请尽快修改默认密码');
      await enter();
    } catch (e) { toast(e.message); }
  }

  $('#btn_login').onclick = login;
  $('#login_pass').addEventListener('keydown', (ev) => {
    if (ev.key === 'Enter') login();
  });

  $('#btn_logout').onclick = async () => {
    await kotvAuth.logout();
    enter();
  };

  $('#btn_save_opts').onclick = async () => {
    try {
      await post('/api/v1/admin/settings', {
        remoteAuth: $('#opt_remote').checked,
        allowRegister: $('#opt_register').checked,
      });
      toast('已保存');
    } catch (e) { toast(e.message); }
  };

  $('#btn_create').onclick = async () => {
    try {
      await kotvAuth.postSealed('/api/v1/admin/users', {
        username: $('#new_user').value.trim(),
        password: $('#new_pass').value,
        role: $('#new_role').value,
      });
      $('#new_user').value = '';
      $('#new_pass').value = '';
      await refresh();
      toast('已创建');
    } catch (e) { toast(e.message); }
  };

  window.addEventListener('kotv-login-required', enter);
  enter();
})();
