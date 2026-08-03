(() => {
  'use strict';

  let danmakuMode = 1;
  let danmakuSize = 25;
  let mediaTimer = null;
  let toastTimer = null;
  let targetScopeId = localStorage.getItem('kotv_remote_user') || localStorage.getItem('kotv_remote_client') || '';

  const $ = (sel) => document.querySelector(sel);
  const $$ = (sel) => document.querySelectorAll(sel);

  function toast(msg) {
    const el = $('#toast');
    el.textContent = msg;
    el.classList.add('show');
    el.classList.remove('hidden');
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => el.classList.remove('show'), 1800);
  }

  function formatTime(ms) {
    const total = Math.max(0, Math.floor(Number(ms || 0) / 1000));
    const h = Math.floor(total / 3600);
    const m = Math.floor((total % 3600) / 60);
    const s = total % 60;
    const pad = (v) => String(v).padStart(2, '0');
    return h > 0 ? `${pad(h)}:${pad(m)}:${pad(s)}` : `${pad(m)}:${pad(s)}`;
  }

  function applyTargetParams(params) {
    if (!targetScopeId) return;
    params.set('scopeId', targetScopeId);
    if (targetScopeId.startsWith('u:')) {
      params.set('userId', targetScopeId.slice(2));
    } else if (targetScopeId.startsWith('c:')) {
      params.set('clientId', targetScopeId.slice(2));
    }
  }

  async function postAction(params) {
    const body = new URLSearchParams(params);
    applyTargetParams(body);
    const res = await fetch('/action', { method: 'POST', body });
    if (!res.ok) throw new Error('请求失败');
    return res.text();
  }

  function renderClients(clients, selected) {
    const sel = $('#target_client');
    if (!sel) return;
    const list = Array.isArray(clients) ? clients : [];
    const prev = selected || targetScopeId || '';
    const opts = ['<option value="">全部 / 自动</option>'];
    list.forEach((c) => {
      const id = c.scopeId || (c.userId ? ('u:' + c.userId) : '') || (c.clientId ? (String(c.clientId).startsWith('c:') || String(c.clientId).startsWith('u:') ? c.clientId : ('c:' + c.clientId)) : '');
      const uid = c.userId || '';
      const title = (c.title || '未播放').slice(0, 24);
      const st = c.state || 'idle';
      const who = uid || c.label || id || '本机';
      const label = `${String(who).slice(0, 10)} · ${title} (${st})`;
      opts.push(`<option value="${escHtml(id)}"${id === prev ? ' selected' : ''}>${escHtml(label)}</option>`);
    });
    sel.innerHTML = opts.join('');
    if (prev && !list.some((c) => {
      const id = c.scopeId || c.clientId || '';
      return id === prev || ('c:' + id) === prev || ('u:' + id) === prev;
    })) {
      sel.value = '';
    } else {
      sel.value = prev;
    }
  }

  async function pollMedia() {
    try {
      const q = new URLSearchParams({ list: '1', users: '1' });
      applyTargetParams(q);
      const res = await fetch('/media?' + q.toString());
      const payload = await res.json();
      const info = payload.media || payload;
      const users = payload.users || payload.clients;
      if (Array.isArray(users)) {
        renderClients(users, targetScopeId || info.scopeId || info.clientId || '');
      }
      const playing = info.playing === true || info.playing === 'true' || info.state === 'playing';
      const pos = Number(info.position || 0);
      const dur = Number(info.duration || 0);
      const pct = dur > 0 ? Math.min(100, (pos / dur) * 100) : 0;

      $('#media_title').textContent = info.title || '未播放';
      $('#media_pos').textContent = formatTime(pos);
      $('#media_dur').textContent = formatTime(dur);
      $('#progress_fill').style.width = `${pct}%`;

      const stateEl = $('#media_state');
      const disc = $('#disc_wrap');
      if (playing) {
        stateEl.textContent = '播放中';
        disc.classList.add('playing');
        $('#icon_play').classList.add('hidden');
        $('#icon_pause').classList.remove('hidden');
      } else if (info.state === 'paused' || dur > 0) {
        stateEl.textContent = '已暂停';
        disc.classList.remove('playing');
        $('#icon_play').classList.remove('hidden');
        $('#icon_pause').classList.add('hidden');
      } else {
        stateEl.textContent = '等待指令';
        disc.classList.remove('playing');
        $('#icon_play').classList.remove('hidden');
        $('#icon_pause').classList.add('hidden');
      }
      $('#conn_state').textContent = '在线';
    } catch (_) {
      $('#conn_state').textContent = '离线';
    }
  }

  function startMediaPoll() {
    pollMedia();
    clearInterval(mediaTimer);
    mediaTimer = setInterval(pollMedia, 1500);
  }

  function showTab(name) {
    $$('.panel').forEach((p) => p.classList.remove('active'));
    $$('.nav-item').forEach((n) => n.classList.remove('active'));
    const panel = $(`#panel-${name}`);
    const nav = $(`.nav-item[data-tab="${name}"]`);
    if (panel) panel.classList.add('active');
    if (nav) nav.classList.add('active');
    if (name === 'play') startMediaPoll();
    if (name === 'file') listFiles(fileRoot);
  }

  async function loadDevice() {
    try {
      const res = await fetch('/device');
      const info = await res.json();
      $('#device_info').textContent = `${info.name || 'KO影视'} · ${info.ip || ''}`;
      $('#conn_state').textContent = '在线';
    } catch (_) {
      $('#device_info').textContent = '无法连接桌面端';
      $('#conn_state').textContent = '离线';
    }
  }

  // Nav
  $$('.nav-item').forEach((btn) => {
    btn.addEventListener('click', () => showTab(btn.dataset.tab));
  });

  // Controls
  $$('[data-action]').forEach((btn) => {
    btn.addEventListener('click', async () => {
      const action = btn.dataset.action;
      try {
        await postAction({ do: 'control', type: action });
        toast('已发送');
        pollMedia();
      } catch (_) {
        toast('发送失败');
      }
    });
  });

  // Search
  async function search() {
    const word = $('#keyword').value.trim();
    if (!word) return toast('请输入关键词');
    try {
      await postAction({ do: 'search', word });
      toast('已发送到桌面搜索');
    } catch (_) {
      toast('搜索失败');
    }
  }
  $('#btn_search').addEventListener('click', search);
  $('#keyword').addEventListener('keydown', (e) => { if (e.key === 'Enter') search(); });

  // Push
  async function push() {
    const url = $('#push_url').value.trim();
    if (!url) return toast('请输入播放地址');
    try {
      await postAction({ do: 'push', url });
      toast('已推送到桌面');
      showTab('play');
    } catch (_) {
      toast('推送失败');
    }
  }
  $('#btn_push').addEventListener('click', push);
  $('#push_url').addEventListener('keydown', (e) => { if (e.key === 'Enter') push(); });

  // Danmaku
  $$('.chip[data-mode]').forEach((chip) => {
    chip.addEventListener('click', () => {
      danmakuMode = Number(chip.dataset.mode);
      $$('.chip[data-mode]').forEach((c) => c.classList.remove('active'));
      chip.classList.add('active');
    });
  });
  $$('.chip[data-size]').forEach((chip) => {
    chip.addEventListener('click', () => {
      danmakuSize = Number(chip.dataset.size);
      $$('.chip[data-size]').forEach((c) => c.classList.remove('active'));
      chip.classList.add('active');
    });
  });
  async function sendDanmaku() {
    const text = $('#danmaku_text').value.trim();
    if (!text) return toast('请输入弹幕');
    const payload = `[0.0,${danmakuMode},${danmakuSize},16777215]${text}`;
    try {
      await postAction({ do: 'danmaku', text: payload });
      $('#danmaku_text').value = '';
      toast('弹幕已发送');
    } catch (_) {
      toast('发送失败');
    }
  }
  $('#btn_danmaku').addEventListener('click', sendDanmaku);
  $('#danmaku_text').addEventListener('keydown', (e) => { if (e.key === 'Enter') sendDanmaku(); });

  // Setting
  async function saveSetting() {
    const name = $('#setting_name').value.trim() || 'vod';
    const text = $('#setting_text').value.trim();
    if (!text) return toast('请输入配置内容');
    try {
      await postAction({ do: 'setting', name, text, config: text });
      toast('配置已保存');
    } catch (_) {
      toast('保存失败');
    }
  }
  $('#btn_setting').addEventListener('click', saveSetting);

  // Files
  let fileRoot = '';
  let fileParent = '';

  function escHtml(s) {
    return String(s || '')
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;');
  }

  function formatFileTime(t) {
    if (t == null || t === '') return '';
    if (typeof t === 'string' && t.includes('-')) return t;
    const n = Number(t);
    if (!Number.isFinite(n) || n <= 0) return '';
    const d = new Date(n < 1e12 ? n * 1000 : n);
    const pad = (v) => String(v).padStart(2, '0');
    return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())} ${pad(d.getHours())}:${pad(d.getMinutes())}`;
  }

  function isDir(node) {
    return node.dir === true || node.dir === 1 || node.dir === '1';
  }

  function fileUrlPath(path) {
    const p = String(path || '').replace(/^\/+/, '');
    return '/file/' + p.split('/').map(encodeURIComponent).join('/');
  }

  async function listFiles(path) {
    const list = $('#file_list');
    list.innerHTML = '<div class="file-empty">加载中…</div>';
    try {
      const res = await fetch(fileUrlPath(path));
      if (!res.ok) throw new Error('load failed');
      const info = await res.json();
      fileRoot = path || '';
      fileParent = info.parent || '';
      $('#file_path_hint').textContent = fileRoot ? ('当前：' + fileRoot) : '应用数据目录';
      const files = Array.isArray(info.files) ? info.files : [];
      list.innerHTML = '';
      if (fileParent || fileRoot) {
        const up = document.createElement('button');
        up.type = 'button';
        up.className = 'file-item';
        up.innerHTML = `<div class="file-icon dir">↑</div><div class="file-meta"><div class="file-name">..</div><div class="file-time">返回上级</div></div>`;
        up.addEventListener('click', () => listFiles(fileParent));
        list.appendChild(up);
      }
      if (files.length === 0) {
        list.appendChild(Object.assign(document.createElement('div'), { className: 'file-empty', textContent: '目录为空' }));
        return;
      }
      files.forEach((node) => {
        const btn = document.createElement('button');
        btn.type = 'button';
        btn.className = 'file-item';
        const dir = isDir(node);
        btn.innerHTML = `<div class="file-icon${dir ? ' dir' : ''}">${dir ? 'D' : 'F'}</div>
          <div class="file-meta"><div class="file-name">${escHtml(node.name)}</div><div class="file-time">${escHtml(formatFileTime(node.time))}</div></div>`;
        btn.addEventListener('click', async () => {
          if (dir) {
            listFiles(node.path || '');
            return;
          }
          try {
            await postAction({ do: 'file', path: node.path || '' });
            toast('已发送到桌面');
            showTab('play');
          } catch (_) {
            toast('发送失败');
          }
        });
        btn.addEventListener('contextmenu', async (e) => {
          e.preventDefault();
          if (!confirm(`删除 ${node.name}？`)) return;
          try {
            const endpoint = dir ? '/delFolder' : '/delFile';
            const body = new URLSearchParams({ path: node.path || '' });
            const res = await fetch(endpoint, { method: 'POST', body });
            if (!res.ok) throw new Error('del failed');
            toast('已删除');
            listFiles(fileRoot);
          } catch (_) {
            toast('删除失败');
          }
        });
        list.appendChild(btn);
      });
    } catch (_) {
      list.innerHTML = '<div class="file-empty">加载失败</div>';
      toast('文件列表加载失败');
    }
  }

  $('#btn_file_up').addEventListener('click', () => listFiles(fileParent));
  $('#btn_file_refresh').addEventListener('click', () => listFiles(fileRoot));
  $('#btn_file_mkdir').addEventListener('click', async () => {
    const name = prompt('新建文件夹名称');
    if (!name || !name.trim()) return;
    try {
      const body = new URLSearchParams({ path: fileRoot, name: name.trim() });
      const res = await fetch('/newFolder', { method: 'POST', body });
      if (!res.ok) throw new Error('mkdir failed');
      toast('已创建');
      listFiles(fileRoot);
    } catch (_) {
      toast('创建失败');
    }
  });
  $('#btn_file_upload').addEventListener('click', () => $('#file_uploader').click());
  $('#file_uploader').addEventListener('change', async () => {
    const input = $('#file_uploader');
    const files = input.files;
    if (!files || files.length === 0) return;
    const form = new FormData();
    form.append('path', fileRoot);
    Array.from(files).forEach((f, i) => {
      form.append(i === 0 ? 'file' : `files-${i}`, f);
    });
    try {
      const res = await fetch('/upload', { method: 'POST', body: form });
      if (!res.ok) throw new Error('upload failed');
      toast('上传完成');
      listFiles(fileRoot);
    } catch (_) {
      toast('上传失败');
    } finally {
      input.value = '';
    }
  });

  // Init
  const targetSel = $('#target_client');
  if (targetSel) {
    targetSel.addEventListener('change', () => {
      targetScopeId = targetSel.value || '';
      localStorage.setItem('kotv_remote_user', targetScopeId);
      pollMedia();
    });
  }
  loadDevice();
  startMediaPoll();
  const tab = new URLSearchParams(location.search).get('tab');
  if (tab && $(`#panel-${tab}`)) showTab(tab);
  const qs = new URLSearchParams(location.search);
  const uid = qs.get('userId');
  const cid = qs.get('clientId');
  if (uid) {
    targetScopeId = uid.startsWith('u:') || uid.startsWith('c:') ? uid : ('u:' + uid);
    localStorage.setItem('kotv_remote_user', targetScopeId);
  } else if (cid) {
    targetScopeId = cid.startsWith('u:') || cid.startsWith('c:') ? cid : ('c:' + cid);
    localStorage.setItem('kotv_remote_user', targetScopeId);
  }
})();
