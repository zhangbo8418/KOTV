/* 遥控页、管理页共用：点播仓库 / 直播源列表 CRUD（走 /api/v1/repos、/config、/live）。 */
(() => {
  'use strict';

  function esc(s) {
    return String(s || '')
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;');
  }

  async function api(path, opts) {
    return kotvAuth.json(path, opts);
  }

  async function post(path, body) {
    return api(path, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(body || {}),
    });
  }

  async function listVod() {
    const data = await api('/api/v1/repos');
    const current = String(data.current || '').trim();
    const repos = Array.isArray(data.repos) ? data.repos : [];
    return {
      current,
      items: repos.map((r) => ({
        url: String(r.url || '').trim(),
        name: String(r.title || r.name || '').trim(),
        current: !!r.current || String(r.url || '').trim() === current,
      })).filter((r) => r.url),
    };
  }

  async function listLive() {
    const data = await api('/api/v1/live');
    const current = String(data.live || '').trim();
    const configs = Array.isArray(data.configs) ? data.configs : [];
    return {
      current,
      items: configs.map((c) => {
        const url = String(c.url || '').trim();
        return {
          url,
          name: String(c.title || c.name || '').trim(),
          current: !!c.current || url === current,
        };
      }).filter((r) => r.url),
    };
  }

  async function list(kind) {
    return kind === 'live' ? listLive() : listVod();
  }

  /** 添加并切换为当前源（点播走 config 加载入库；直播走 live load）。 */
  async function addOrSwitch(kind, url, name) {
    url = String(url || '').trim();
    if (!url) throw new Error('请输入配置地址');
    if (kind === 'live') {
      await post('/api/v1/live', { action: 'load', url, force: true });
      if (name) {
        try {
          await post('/api/v1/live', { action: 'edit', oldUrl: url, url, name });
        } catch (_) { /* 备注失败不挡切换 */ }
      }
      return;
    }
    await post('/api/v1/config', { source: url });
    if (name) {
      try {
        await post('/api/v1/repos', { action: 'edit', oldUrl: url, url, name });
      } catch (_) { /* 备注失败不挡切换 */ }
    }
  }

  async function edit(kind, oldUrl, url, name) {
    oldUrl = String(oldUrl || '').trim();
    url = String(url || '').trim();
    name = String(name || '').trim();
    if (!url) throw new Error('请输入配置地址');
    if (kind === 'live') {
      await post('/api/v1/live', { action: 'edit', oldUrl: oldUrl || url, url, name });
      return;
    }
    await post('/api/v1/repos', { action: 'edit', oldUrl: oldUrl || url, url, name });
  }

  async function remove(kind, url) {
    url = String(url || '').trim();
    if (!url) throw new Error('缺少地址');
    if (kind === 'live') {
      await post('/api/v1/live', { action: 'delete', url });
      return;
    }
    await api('/api/v1/repos?url=' + encodeURIComponent(url), { method: 'DELETE' });
  }

  /**
   * 把列表渲到 container；onToast(msg) 可选。
   * @param {{kind:string, container:HTMLElement, onToast?:Function}} opts
   */
  async function renderList(opts) {
    const kind = opts.kind === 'live' ? 'live' : 'vod';
    const el = opts.container;
    const toast = typeof opts.onToast === 'function' ? opts.onToast : () => {};
    if (!el) return;
    el.innerHTML = '<div class="file-empty">加载中…</div>';
    let data;
    try {
      data = await list(kind);
    } catch (e) {
      el.innerHTML = `<div class="file-empty">${esc(e.message || '加载失败')}</div>`;
      return;
    }
    if (!data.items.length) {
      el.innerHTML = '<div class="file-empty">暂无仓库，请在上方添加</div>';
      return;
    }
    el.innerHTML = '';
    data.items.forEach((item) => {
      const row = document.createElement('div');
      row.className = 'file-item repo-item' + (item.current ? ' repo-current' : '');
      const label = item.name || item.url;
      row.innerHTML = `
        <div class="file-icon" aria-hidden="true">
          <svg viewBox="0 0 24 24" width="18" height="18"><path fill="currentColor" d="M4 6H2v14c0 1.1.9 2 2 2h14v-2H4V6zm16-4H8c-1.1 0-2 .9-2 2v12c0 1.1.9 2 2 2h12c1.1 0 2-.9 2-2V4c0-1.1-.9-2-2-2zm-1 9H9V9h10v2zm-4 4H9v-2h6v2zm4-8H9V5h10v2z"/></svg>
        </div>
        <div class="file-meta">
          <div class="file-name">${esc(label)}${item.current ? ' · 当前' : ''}</div>
          <div class="file-time">${esc(item.url)}</div>
        </div>
        <div class="repo-actions"></div>`;
      const actions = row.querySelector('.repo-actions');

      const btnUse = document.createElement('button');
      btnUse.type = 'button';
      btnUse.className = 'chip';
      btnUse.textContent = item.current ? '已用' : '切换';
      btnUse.disabled = !!item.current;
      btnUse.onclick = async () => {
        try {
          await addOrSwitch(kind, item.url, item.name);
          toast('已切换');
          await renderList(opts);
        } catch (e) {
          toast(e.message || '切换失败');
        }
      };

      const btnEdit = document.createElement('button');
      btnEdit.type = 'button';
      btnEdit.className = 'chip';
      btnEdit.textContent = '编辑';
      btnEdit.onclick = async () => {
        const nextUrl = prompt('地址', item.url);
        if (nextUrl == null) return;
        const nextName = prompt('备注名', item.name || '');
        if (nextName == null) return;
        try {
          await edit(kind, item.url, nextUrl.trim(), nextName.trim());
          toast('已保存');
          await renderList(opts);
        } catch (e) {
          toast(e.message || '保存失败');
        }
      };

      const btnDel = document.createElement('button');
      btnDel.type = 'button';
      btnDel.className = 'chip danger';
      btnDel.textContent = '删除';
      btnDel.onclick = async () => {
        if (!confirm('删除 ' + (item.name || item.url) + '？')) return;
        try {
          await remove(kind, item.url);
          toast('已删除');
          await renderList(opts);
        } catch (e) {
          toast(e.message || '删除失败');
        }
      };

      actions.append(btnUse, btnEdit, btnDel);
      el.appendChild(row);
    });
  }

  /**
   * 绑定一个设置面板：kindSelect、urlInput、nameInput、listEl、addBtn、refreshBtn。
   */
  function bindPanel(cfg) {
    const kindEl = cfg.kindSelect;
    const urlEl = cfg.urlInput;
    const nameEl = cfg.nameInput;
    const listEl = cfg.listEl;
    const toast = typeof cfg.onToast === 'function' ? cfg.onToast : () => {};

    const opts = () => ({
      kind: kindEl ? kindEl.value : 'vod',
      container: listEl,
      onToast: toast,
    });

    const refresh = () => renderList(opts());

    if (kindEl) {
      kindEl.addEventListener('change', () => { refresh(); });
    }
    if (cfg.refreshBtn) {
      cfg.refreshBtn.addEventListener('click', () => { refresh(); });
    }
    if (cfg.addBtn) {
      cfg.addBtn.addEventListener('click', async () => {
        const kind = kindEl ? kindEl.value : 'vod';
        const url = urlEl ? urlEl.value.trim() : '';
        const name = nameEl ? nameEl.value.trim() : '';
        try {
          await addOrSwitch(kind, url, name);
          if (urlEl) urlEl.value = '';
          if (nameEl) nameEl.value = '';
          toast('已保存并切换');
          await refresh();
        } catch (e) {
          toast(e.message || '保存失败');
        }
      });
    }
    return { refresh };
  }

  window.kotvRepos = {
    list,
    addOrSwitch,
    edit,
    remove,
    renderList,
    bindPanel,
  };
})();
