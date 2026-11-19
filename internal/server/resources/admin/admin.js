(() => {
  'use strict';

  const $ = (s, el = document) => el.querySelector(s);
  const $$ = (s, el = document) => Array.from(el.querySelectorAll(s));
  const api = (path, opts) => kotvAuth.json(path, opts);
  const post = (path, body) =>
    api(path, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(body || {}),
    });
  const put = (path, body) =>
    api(path, {
      method: 'PUT',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(body || {}),
    });
  const del = (path) => api(path, { method: 'DELETE' });

  const CAP_KEYS = [
    'allowAddRepo', 'allowDownload', 'allowBt', 'allowLive', 'allowDanmakuSearch',
    'allowRemoteControl', 'allowCast', 'allowDlna', 'allowPip', 'allowBgPlay',
    'allowSearch', 'allowKeep', 'allowHistory', 'forceIncognito', 'allowSync',
  ];
  const CAP_LABELS = {
    allowAddRepo: '添加仓库',
    allowDownload: '下载',
    allowBt: 'BT',
    allowLive: '直播',
    allowDanmakuSearch: '弹幕搜索',
    allowRemoteControl: '远端控制',
    allowCast: '投屏',
    allowDlna: 'DLNA',
    allowPip: '画中画',
    allowBgPlay: '后台播放',
    allowSearch: '搜索',
    allowKeep: '收藏',
    allowHistory: '历史',
    forceIncognito: '强制无痕',
    allowSync: '同步',
  };
  const EXTRA_SETTING_KEYS = [
    ['updateUrl', '更新地址'],
    ['forceUpdate', '强制更新 (true/false)'],
    ['maintenance', '维护模式 (true/false)'],
    ['maintenanceMsg', '维护文案'],
    ['minClientVersion', '最低版本'],
    ['maxDevices', '最大设备数'],
    ['maxSessions', '最大会话数'],
    ['ipAllow', 'IP 白名单'],
    ['ipDeny', 'IP 黑名单'],
    ['accessHours', '准入时段'],
    ['quietHours', '静默时段'],
    ['wallpaper', '壁纸'],
    ['logo', 'Logo'],
    ['banner', '横幅'],
    ['aboutUrl', '关于页链接'],
    ['supportUrl', '支持页链接'],
    ['footer', '页脚'],
    ['welcome', '欢迎语'],
  ];
  const ROLE_LABELS = { user: '用户', admin: '管理员' };
  const NOTICE_KIND_LABELS = { banner: '横幅', dialog: '弹窗', toast: '轻提示' };
  const PUSH_KIND_LABELS = { play: '播放', detail: '详情', live: '直播', url: '链接' };
  const SCOPE_LABELS = { all: '全部', group: '分组', user: '用户' };
  const AUDIT_ACTION_LABELS = {
    'group.upsert': '保存分组',
    'group.delete': '删除分组',
    'group.vods': '更新点播仓',
    'group.lives': '更新直播源',
    'group.settings': '更新分组设置',
    'group.import': '导入分组',
    'notice.create': '发布公告',
    'notice.update': '更新公告',
    'notice.delete': '删除公告',
    'push.open': '推送打开',
    'invite.upsert': '保存邀请码',
    'settings.save': '保存设置',
    'session.kick': '踢下线',
    'ops.logs-clear': '清理日志',
    'ops.cache-purge': '清缓存',
  };

  const state = {
    rangeDays: 1,
    groups: [],
    users: [],
    selectedGroupId: null,
    repoPanel: null,
    repoLoadMap: {},
    currentView: 'overview',
    consoleSettings: {},
    sysTimer: null,
  };

  function labelOf(map, key, fallback) {
    const k = String(key ?? '').trim();
    if (!k) return fallback || '—';
    return (map && map[k]) || fallback || k;
  }

  function fmtActor(actor) {
    const a = String(actor ?? '').trim();
    if (!a || a === 'local') return '本机';
    return a;
  }

  function fmtAuditAction(action) {
    return labelOf(AUDIT_ACTION_LABELS, action, action || '—');
  }

  function localInputToMs(el) {
    const v = el && el.value;
    if (!v) return 0;
    const t = Date.parse(v);
    return Number.isFinite(t) ? t : 0;
  }

  function msToLocalInput(ms) {
    ms = Number(ms) || 0;
    if (!ms) return '';
    const d = new Date(ms);
    if (Number.isNaN(d.getTime())) return '';
    const pad = (n) => String(n).padStart(2, '0');
    return (
      d.getFullYear() +
      '-' +
      pad(d.getMonth() + 1) +
      '-' +
      pad(d.getDate()) +
      'T' +
      pad(d.getHours()) +
      ':' +
      pad(d.getMinutes())
    );
  }

  function bindDateTimePickers(root) {
    $$('input[type="datetime-local"]', root || document).forEach((el) => {
      if (el.dataset.pickerBound === '1') return;
      el.dataset.pickerBound = '1';
      if (!el.title) el.title = '点击选择日期与时间';
      el.addEventListener('click', () => {
        if (typeof el.showPicker === 'function') {
          try {
            el.showPicker();
          } catch (_) {}
        }
      });
    });
  }

  function toast(msg) {
    const el = $('#toast');
    el.textContent = msg;
    el.classList.add('show');
    clearTimeout(toast._t);
    toast._t = setTimeout(() => el.classList.remove('show'), 2000);
  }

  function esc(s) {
    return String(s ?? '')
      .replace(/&/g, '&amp;')
      .replace(/</g, '&lt;')
      .replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;');
  }

  function fmtTime(ms) {
    if (!ms) return '—';
    const d = new Date(Number(ms));
    if (Number.isNaN(d.getTime())) return String(ms);
    const pad = (n) => String(n).padStart(2, '0');
    return (
      d.getFullYear() +
      '/' +
      pad(d.getMonth() + 1) +
      '/' +
      pad(d.getDate()) +
      ' ' +
      pad(d.getHours()) +
      ':' +
      pad(d.getMinutes()) +
      ':' +
      pad(d.getSeconds())
    );
  }

  function wrapTable(inner) {
    return '<div class="table-scroll">' + inner + '</div>';
  }

  function rangeParams() {
    const to = Date.now();
    const from =
      state.rangeDays === 1
        ? new Date().setHours(0, 0, 0, 0)
        : to - state.rangeDays * 86400000;
    const q = new URLSearchParams({ from: String(from), to: String(to) });
    const gid = $('#ov_group')?.value || '';
    const plat = $('#ov_platform')?.value || '';
    if (gid) q.set('groupId', gid);
    if (plat) q.set('platform', plat);
    return q;
  }

  function groupName(id) {
    if (!id) return '—';
    const g = state.groups.find((x) => x.id === id);
    return g ? g.name : id;
  }

  function fillGroupSelects() {
    const opts =
      '<option value="">全部分组</option>' +
      state.groups
        .map((g) => `<option value="${esc(g.id)}">${esc(g.name)}</option>`)
        .join('');
    const plain =
      state.groups
        .map((g) => `<option value="${esc(g.id)}">${esc(g.name)}</option>`)
        .join('') || '<option value="default">默认</option>';
    const withEmpty =
      '<option value="">不限</option>' +
      state.groups.map((g) => `<option value="${esc(g.id)}">${esc(g.name)}</option>`).join('');

    if ($('#ov_group')) {
      const cur = $('#ov_group').value;
      $('#ov_group').innerHTML = opts;
      $('#ov_group').value = cur;
    }
    if ($('#new_group')) {
      const cur = $('#new_group').value;
      $('#new_group').innerHTML = plain;
      if (cur) $('#new_group').value = cur;
    }
    if ($('#inv_group')) {
      const cur = $('#inv_group').value;
      $('#inv_group').innerHTML = plain;
      if (cur) $('#inv_group').value = cur;
    }
    if ($('#push_group')) {
      const cur = $('#push_group').value;
      $('#push_group').innerHTML = withEmpty;
      if (cur) $('#push_group').value = cur;
    }
    if ($('#set_default_group')) {
      const cur = $('#set_default_group').value || state.consoleSettings.defaultGroupId || 'default';
      $('#set_default_group').innerHTML = plain;
      $('#set_default_group').value = cur;
    }
    if ($('#grp_copy_of')) {
      const cur = $('#grp_copy_of').value;
      $('#grp_copy_of').innerHTML =
        '<option value="">不复制</option>' +
        state.groups.map((g) => `<option value="${esc(g.id)}">${esc(g.name)}</option>`).join('');
      if (cur) $('#grp_copy_of').value = cur;
    }
  }

  function fillUserSelects(preferId) {
    const users = state.users || [];
    const opts =
      '<option value="">不限（可配合分组）</option>' +
      users
        .map(
          (u) =>
            `<option value="${esc(u.id)}">${esc(u.username || u.id)}` +
            (u.groupName || u.groupId ? ` · ${esc(u.groupName || groupName(u.groupId))}` : '') +
            `</option>`
        )
        .join('');
    if ($('#push_user')) {
      const cur = preferId || $('#push_user').value;
      $('#push_user').innerHTML = opts;
      if (cur) $('#push_user').value = cur;
    }
    syncNoticeTargetOptions();
  }

  function syncNoticeTargetOptions(keepValue) {
    const scope = $('#nt_scope')?.value || 'all';
    const sel = $('#nt_target');
    const wrap = $('#nt_target_wrap');
    const label = $('#nt_target_label');
    if (!sel) return;
    const cur = keepValue != null ? keepValue : sel.value;
    if (scope === 'all') {
      if (wrap) wrap.style.opacity = '0.55';
      if (label) label.textContent = '目标（全部）';
      sel.innerHTML = '<option value="">全部用户</option>';
      sel.disabled = true;
      return;
    }
    if (wrap) wrap.style.opacity = '1';
    sel.disabled = false;
    if (scope === 'group') {
      if (label) label.textContent = '目标分组';
      sel.innerHTML =
        '<option value="">选择分组</option>' +
        (state.groups || [])
          .map((g) => `<option value="${esc(g.id)}">${esc(g.name)}</option>`)
          .join('');
    } else {
      if (label) label.textContent = '目标用户';
      sel.innerHTML =
        '<option value="">选择用户</option>' +
        (state.users || [])
          .map((u) => `<option value="${esc(u.id)}">${esc(u.username || u.id)}</option>`)
          .join('');
    }
    if (cur) sel.value = cur;
  }

  function resetNoticeForm() {
    if ($('#nt_id')) $('#nt_id').value = '';
    if ($('#nt_title')) $('#nt_title').value = '';
    if ($('#nt_body')) $('#nt_body').value = '';
    if ($('#nt_link')) $('#nt_link').value = '';
    if ($('#nt_priority')) $('#nt_priority').value = '0';
    if ($('#nt_sticky')) $('#nt_sticky').checked = false;
    if ($('#nt_starts')) $('#nt_starts').value = '';
    if ($('#nt_ends')) $('#nt_ends').value = '';
    if ($('#nt_scope')) $('#nt_scope').value = 'all';
    if ($('#nt_kind')) $('#nt_kind').value = 'banner';
    if ($('#nt_form_title')) $('#nt_form_title').textContent = '发布公告';
    if ($('#btn_nt_save')) $('#btn_nt_save').textContent = '发布';
    if ($('#btn_nt_cancel')) $('#btn_nt_cancel').classList.add('hidden');
    syncNoticeTargetOptions('');
  }

  function fillNoticeForm(n) {
    if (!n) return resetNoticeForm();
    $('#nt_id').value = n.id || '';
    $('#nt_title').value = n.title || '';
    $('#nt_body').value = n.body || '';
    $('#nt_link').value = n.link || '';
    $('#nt_priority').value = n.priority ?? 0;
    $('#nt_sticky').checked = !!n.sticky;
    $('#nt_kind').value = n.kind || 'banner';
    $('#nt_scope').value = n.scope || 'all';
    $('#nt_starts').value = msToLocalInput(n.startsAt);
    $('#nt_ends').value = msToLocalInput(n.endsAt);
    $('#nt_form_title').textContent = '编辑公告';
    $('#btn_nt_save').textContent = '保存';
    $('#btn_nt_cancel').classList.remove('hidden');
    syncNoticeTargetOptions(n.targetId || '');
  }

  /* ========== Navigation ========== */
  function setSidebarOpen(open) {
    $('#sidebar').classList.toggle('open', open);
    $('#scrim').classList.toggle('show', open);
  }

  function showView(name) {
    state.currentView = name;
    $$('.view').forEach((v) => v.classList.toggle('active', v.id === 'view_' + name));
    $$('#nav button').forEach((b) => b.classList.toggle('active', b.dataset.view === name));
    const view = $('#view_' + name);
    $('#view_title').textContent = view?.dataset.title || name;
    setSidebarOpen(false);
    armSystemPoll(name === 'overview');
    loadView(name).catch((e) => toast(e.message || String(e)));
  }

  function armSystemPoll(on) {
    if (state.sysTimer) {
      clearInterval(state.sysTimer);
      state.sysTimer = null;
    }
    if (!on) return;
    state.sysTimer = setInterval(() => {
      if (state.currentView !== 'overview') return;
      refreshSystemOnly().catch(() => {});
    }, 5000);
  }

  async function refreshSystemOnly() {
    const q = rangeParams();
    const sysRes = await api('/api/v1/admin/stats/system?' + q).catch(() => null);
    if (!sysRes || !sysRes.system) return;
    const onlineN = sysRes.onlineApprox ?? '—';
    $('#online_badge').textContent = '在线 ≈ ' + onlineN;
    renderSystemGauges(sysRes.system, sysRes.onlineApprox, sysRes.sessionCount);
    renderOnlineSessions(sysRes.sessions || []);
  }

  async function loadView(name) {
    switch (name) {
      case 'overview':
        return refreshOverview();
      case 'groups':
        return refreshGroups();
      case 'users':
        return refreshUsers();
      case 'repos':
        return refreshRepos();
      case 'messages':
        return refreshMessages();
      case 'security':
        return refreshSecurity();
      case 'ops':
        return refreshOps();
      case 'settings':
        return refreshSettings();
      default:
        break;
    }
  }

  function showPanel(on, hint) {
    $('#login_box').classList.toggle('hidden', on);
    $('#panel').classList.toggle('hidden', !on);
    $('#login_form').classList.toggle('hidden', !!hint);
    $('#login_hint').textContent =
      hint || '本机打开无需登录；远端打开须以管理员登录。新装默认 admin / admin，请尽快改密。';
  }

  /* ========== Shared data ========== */
  async function ensureUsers() {
    if (state.users && state.users.length) return state.users;
    try {
      const data = await api('/api/v1/admin/users');
      state.users = data.users || [];
    } catch (_) {
      state.users = state.users || [];
    }
    return state.users;
  }

  async function loadGroups() {
    const data = await api('/api/v1/admin/groups');
    state.groups = data.groups || [];
    fillGroupSelects();
    return state.groups;
  }

  async function loadConsoleSettings() {
    try {
      state.consoleSettings = await api('/api/v1/admin/console-settings');
    } catch (_) {
      state.consoleSettings = {};
    }
    return state.consoleSettings;
  }

  /* ========== Overview ========== */
  function renderTopList(el, rows) {
    if (!rows || !rows.length) {
      el.innerHTML = '<div class="empty">暂无数据</div>';
      return;
    }
    el.innerHTML = wrapTable(
      '<table class="data"><thead><tr><th>名称</th><th>次数</th><th>用户</th></tr></thead><tbody>' +
        rows
          .slice(0, 12)
          .map(
            (r) =>
              `<tr><td class="cell-wrap" title="${esc(r.refId || '')}">${esc(r.refName || r.refId || '—')}</td>` +
              `<td>${esc(r.count)}</td><td>${esc(r.users)}</td></tr>`
          )
          .join('') +
        '</tbody></table>'
    );
  }

  function fmtBytes(n) {
    n = Number(n) || 0;
    if (n < 1024) return n + ' B';
    const u = ['KB', 'MB', 'GB', 'TB'];
    let i = -1;
    do {
      n /= 1024;
      i++;
    } while (n >= 1024 && i < u.length - 1);
    return n.toFixed(n >= 10 || i === 0 ? 0 : 1) + ' ' + u[i];
  }

  function fmtUptime(sec) {
    sec = Math.max(0, Math.floor(Number(sec) || 0));
    const d = Math.floor(sec / 86400);
    const h = Math.floor((sec % 86400) / 3600);
    const m = Math.floor((sec % 3600) / 60);
    if (d > 0) return d + '天' + h + '时';
    if (h > 0) return h + '时' + m + '分';
    return m + '分' + (sec % 60) + '秒';
  }

  function gaugeTone(pct) {
    if (pct >= 90) return 'danger';
    if (pct >= 75) return 'warn';
    return '';
  }

  function renderSystemGauges(sys, onlineApprox, sessionCount) {
    const el = $('#ov_system');
    const meta = $('#ov_system_meta');
    if (!el) return;
    if (!sys) {
      el.innerHTML = '<div class="empty">暂无系统指标</div>';
      if (meta) meta.innerHTML = '';
      return;
    }
    const cpuPct = Number(sys.cpuPercent || 0);
    const cpuCap = Math.max(100, (Number(sys.numCPU) || 1) * 100);
    const cpuBar = Math.min(100, (cpuPct / cpuCap) * 100);
    const memPct = Number(sys.memPercent || 0);
    const diskPct = Number(sys.diskPercent || 0);
    const httpConns = Number(sys.httpConns || 0);
    const load1 = Number(sys.load1 || 0);
    const numCPU = Number(sys.numCPU) || 1;
    const loadPct = Math.min(100, (load1 / numCPU) * 100);

    const gauges = [
      {
        label: 'CPU',
        value: cpuPct.toFixed(1) + '%',
        pct: cpuBar,
        sub: '负载 ' + load1.toFixed(2) + ' / ' + numCPU + ' 核',
        tone: gaugeTone(cpuBar),
      },
      {
        label: '内存',
        value: memPct.toFixed(1) + '%',
        pct: memPct,
        sub: fmtBytes(sys.memUsed) + ' / ' + fmtBytes(sys.memTotal),
        tone: gaugeTone(memPct),
      },
      {
        label: '数据盘',
        value: diskPct.toFixed(1) + '%',
        pct: diskPct,
        sub: fmtBytes(sys.diskUsed) + ' / ' + fmtBytes(sys.diskTotal),
        tone: gaugeTone(diskPct),
      },
      {
        label: '连接',
        value: String(httpConns),
        pct: Math.min(100, httpConns * 5),
        sub: 'HTTP 活跃 · 近5分在线 ≈ ' + (onlineApprox ?? '—'),
        tone: '',
      },
      {
        label: '负载',
        value: load1.toFixed(2),
        pct: loadPct,
        sub: '5分 ' + Number(sys.load5 || 0).toFixed(2) + ' · 15分 ' + Number(sys.load15 || 0).toFixed(2),
        tone: gaugeTone(loadPct),
      },
      {
        label: '进程内存',
        value: fmtBytes(sys.procRSS || sys.heapInuse),
        pct: sys.memTotal ? Math.min(100, ((sys.procRSS || 0) / sys.memTotal) * 100) : 0,
        sub: '堆 ' + fmtBytes(sys.heapInuse) + ' · 协程 ' + (sys.goroutines ?? '—'),
        tone: '',
      },
    ];

    el.innerHTML = gauges
      .map(
        (g) =>
          `<div class="sys-gauge ${g.tone}">` +
          `<div class="sg-head"><span class="sg-label">${esc(g.label)}</span>` +
          `<span class="sg-value">${esc(g.value)}</span></div>` +
          `<div class="sg-bar"><i style="width:${Math.max(0, Math.min(100, g.pct)).toFixed(1)}%"></i></div>` +
          `<div class="sg-sub">${esc(g.sub)}</div></div>`
      )
      .join('');

    if (meta) {
      const net =
        sys.netBytesRecv || sys.netBytesSent
          ? `网卡累计 ↓${fmtBytes(sys.netBytesRecv)} ↑${fmtBytes(sys.netBytesSent)}`
          : '';
      meta.innerHTML =
        `<span>运行 <strong>${esc(fmtUptime(sys.uptimeSec))}</strong></span>` +
        `<span>${esc(sys.goos)}/${esc(sys.goarch)} · ${esc(sys.goVersion || '')}</span>` +
        (net ? `<span>${esc(net)}</span>` : '') +
        (sys.diskPath ? `<span title="${esc(sys.diskPath)}">数据目录磁盘</span>` : '');
    }
    const cnt = $('#ov_session_count');
    if (cnt) cnt.textContent = sessionCount != null ? '(' + sessionCount + ')' : '';
  }

  function renderRecentMessages(notices, pushLogs) {
    const el = $('#ov_messages');
    if (!el) return;
    const rows = [];
    (notices || []).slice(0, 6).forEach((n) => {
      rows.push({
        at: n.createdAt,
        kind: '公告',
        title: n.title || '—',
        sub:
          labelOf(SCOPE_LABELS, n.scope, n.scope || '全部') +
          (n.targetId ? '/' + n.targetId : '') +
          ' · ' +
          labelOf(NOTICE_KIND_LABELS, n.kind, n.kind || ''),
      });
    });
    (pushLogs || []).slice(0, 6).forEach((p) => {
      let name = labelOf(PUSH_KIND_LABELS, p.kind, p.kind || '推送');
      try {
        const payload = typeof p.payload === 'string' ? JSON.parse(p.payload) : p.payload;
        if (payload && (payload.name || payload.url || payload.id)) {
          name = payload.name || payload.url || payload.id;
        }
      } catch (_) {}
      rows.push({
        at: p.at,
        kind: '推送',
        title: name,
        sub: (p.target || '—') + ' · ' + fmtActor(p.actor),
      });
    });
    rows.sort((a, b) => (b.at || 0) - (a.at || 0));
    const top = rows.slice(0, 8);
    if (!top.length) {
      el.innerHTML = '<div class="empty">暂无公告或推送</div>';
      return;
    }
    el.innerHTML = wrapTable(
      '<table class="data"><thead><tr><th>时间</th><th>类型</th><th>内容</th></tr></thead><tbody>' +
        top
          .map(
            (r) =>
              `<tr><td>${esc(fmtTime(r.at))}</td><td><span class="badge muted">${esc(r.kind)}</span></td>` +
              `<td class="cell-wrap">${esc(r.title)}<div style="font-size:.72rem;color:var(--admin-muted)">${esc(r.sub)}</div></td></tr>`
          )
          .join('') +
        '</tbody></table>'
    );
  }

  async function refreshOverview() {
    const q = rangeParams();
    const [sumRes, sysRes, repos, lives, plays, searches, denies, errors, noticesRes, pushRes] =
      await Promise.all([
        api('/api/v1/admin/stats/summary?' + q),
        api('/api/v1/admin/stats/system?' + q).catch(() => ({})),
        api('/api/v1/admin/stats/repos?' + q).catch(() => ({ rows: [] })),
        api('/api/v1/admin/stats/lives?' + q).catch(() => ({ rows: [] })),
        api('/api/v1/admin/stats/plays?' + q).catch(() => ({ rows: [] })),
        api('/api/v1/admin/stats/searches?' + q).catch(() => ({ rows: [] })),
        api('/api/v1/admin/stats/denies?' + q).catch(() => ({ rows: [] })),
        api('/api/v1/admin/stats/errors?' + q).catch(() => ({ rows: [] })),
        api('/api/v1/admin/notices').catch(() => ({ notices: [] })),
        api('/api/v1/admin/push/logs?limit=20').catch(() => ({ logs: [] })),
      ]);

    const s = sumRes.summary || {};
    const onlineN = sysRes.onlineApprox ?? '—';
    $('#online_badge').textContent = '在线 ≈ ' + onlineN;

    const kpis = [
      { label: '活跃用户 (DAU)', value: s.dau ?? 0, sub: '窗口内去重' },
      { label: '播放', value: s.plays ?? 0, sub: '直播播放 ' + (s.livePlays ?? 0) },
      { label: '搜索', value: s.searches ?? 0, sub: '仓加载 ' + (s.configLoads ?? 0) },
      {
        label: '错误',
        value: s.errors ?? 0,
        sub: '错误率 ' + ((Number(s.errorRate || 0) * 100).toFixed(1) + '%'),
      },
      { label: '近 5 分在线', value: onlineN, sub: '近似值' },
      { label: '事件总量', value: s.events ?? 0, sub: '' },
    ];
    $('#kpi_row').innerHTML = kpis
      .map(
        (k, i) =>
          `<div class="kpi" style="animation-delay:${i * 40}ms"><div class="label">${esc(k.label)}</div>` +
          `<div class="value">${esc(k.value)}</div>` +
          (k.sub ? `<div class="sub">${esc(k.sub)}</div>` : '') +
          `</div>`
      )
      .join('');

    const plats = sumRes.platforms || [];
    const platEl = $('#ov_platforms');
    if (!plats.length) {
      platEl.innerHTML = '<div class="empty">暂无平台数据</div>';
    } else {
      platEl.innerHTML =
        '<table class="data"><thead><tr><th>平台</th><th>用户</th></tr></thead><tbody>' +
        plats
          .map((p) => `<tr><td>${esc(p.platform)}</td><td>${esc(p.users)}</td></tr>`)
          .join('') +
        '</tbody></table>';
      const sel = $('#ov_platform');
      const cur = sel.value;
      const known = new Set(['', ...plats.map((p) => p.platform)]);
      sel.innerHTML =
        '<option value="">全部平台</option>' +
        plats.map((p) => `<option value="${esc(p.platform)}">${esc(p.platform)}</option>`).join('');
      if (known.has(cur)) sel.value = cur;
    }

    const audit = sumRes.audit || [];
    const auditEl = $('#ov_audit');
    if (!audit.length) {
      auditEl.innerHTML = '<div class="empty">暂无审计</div>';
    } else {
      auditEl.innerHTML = wrapTable(
        '<table class="data"><thead><tr><th>时间</th><th>操作</th><th>操作者</th></tr></thead><tbody>' +
          audit
            .slice(0, 10)
            .map(
              (a) =>
                `<tr><td>${esc(fmtTime(a.at))}</td><td>${esc(fmtAuditAction(a.action))}` +
                (a.target ? ` <span class="badge muted" title="${esc(a.target)}">${esc(a.target)}</span>` : '') +
                `</td><td>${esc(fmtActor(a.actor))}</td></tr>`
            )
            .join('') +
          '</tbody></table>'
      );
    }

    renderTopList($('#ov_repos'), repos.rows || []);
    renderTopList($('#ov_lives'), lives.rows || []);
    renderTopList($('#ov_plays'), plays.rows || []);
    renderTopList($('#ov_searches'), searches.rows || []);
    renderTopList($('#ov_denies'), denies.rows || []);
    renderTopList($('#ov_errors'), errors.rows || []);
    renderRecentMessages(noticesRes.notices || [], pushRes.logs || []);
    renderSystemGauges(sysRes.system, sysRes.onlineApprox, sysRes.sessionCount);
    renderOnlineSessions(sysRes.sessions || []);
  }

  function renderOnlineSessions(sessions) {
    const el = $('#ov_sessions');
    if (!el) return;
    if (!sessions.length) {
      el.innerHTML = '<div class="empty">当前无在线会话</div>';
      return;
    }
    el.innerHTML = wrapTable(
      '<table class="data"><thead><tr><th>用户</th><th>分组</th><th>平台</th><th>IP</th><th>媒体</th><th>活跃</th><th></th></tr></thead><tbody></tbody></table>'
    );
    const tb = $('tbody', el);
    sessions.forEach((s) => {
      const tr = document.createElement('tr');
      const uid = s.userId || s.user_id || '';
      tr.innerHTML =
        `<td>${esc(s.username || uid || '—')}</td>` +
        `<td>${esc(s.groupName || s.groupId || '—')}</td>` +
        `<td>${esc(s.platform || '—')} ${esc(s.arch || '')}</td>` +
        `<td>${esc(s.ip || '—')}</td>` +
        `<td title="${esc(s.media || s.title || '')}">${esc((s.media || s.title || '—').toString().slice(0, 40))}</td>` +
        `<td>${esc(fmtTime(s.lastSeen || s.at || s.activeAt))}</td>` +
        `<td class="actions"></td>`;
      if (uid) {
        const b = document.createElement('button');
        b.type = 'button';
        b.className = 'btn sm danger';
        b.textContent = '踢下线';
        b.onclick = async () => {
          if (!confirm('强制下线该用户？')) return;
          try {
            await post('/api/v1/admin/sessions', { action: 'kick', userId: uid });
            toast('已踢下线');
            refreshOverview();
          } catch (e) {
            toast(e.message);
          }
        };
        tr.querySelector('.actions').appendChild(b);
      }
      tb.appendChild(tr);
    });
  }

  /* ========== Groups ========== */
  async function refreshGroups() {
    await loadGroups();
    const list = $('#grp_list');
    if (!state.groups.length) {
      list.innerHTML = '<div class="empty">暂无分组</div>';
      $('#grp_editor').innerHTML = '<p class="empty">创建分组后在此编辑</p>';
      return;
    }
    list.innerHTML = state.groups
      .map((g) => {
        const active = g.id === state.selectedGroupId ? ' active' : '';
        return (
          `<div class="list-item${active}" data-id="${esc(g.id)}">` +
          `<div class="name">${esc(g.name)} ${g.enabled === false ? '<span class="badge warn">停用</span>' : ''}</div>` +
          `<div class="meta">${esc(g.id)}${g.note ? ' · ' + esc(g.note) : ''}</div></div>`
        );
      })
      .join('');
    $$('.list-item', list).forEach((el) => {
      el.onclick = () => {
        state.selectedGroupId = el.dataset.id;
        refreshGroups();
      };
    });
    if (state.selectedGroupId) {
      const g = state.groups.find((x) => x.id === state.selectedGroupId);
      if (g) renderGroupEditor(g);
      else {
        state.selectedGroupId = null;
        $('#grp_editor').innerHTML = '<p class="empty">选择左侧分组进行编辑</p>';
      }
    }
  }

  async function fetchReposForPicker() {
    try {
      const data = await api('/api/v1/repos');
      return data.repos || [];
    } catch (_) {
      return [];
    }
  }

  async function fetchSitesForHides() {
    try {
      const data = await api('/api/v1/sites');
      const sites = data.sites || data.Sites || [];
      if (Array.isArray(sites)) {
        return sites
          .map((s) => ({
            key: s.key || s.Key || '',
            name: s.name || s.Name || s.key || '',
          }))
          .filter((s) => s.key);
      }
    } catch (_) { /* ignore */ }
    return [];
  }

  function truthyStr(v) {
    const s = String(v || '').trim().toLowerCase();
    return s === '1' || s === 'true' || s === 'yes' || s === 'on';
  }

  function liveRowHtml(l, i) {
    const row = l || {};
    return (
      `<tr data-live-row>` +
      `<td><input class="field" data-live="name" value="${esc(row.name || '')}" placeholder="名称">` +
      `<input type="hidden" data-live="id" value="${esc(row.id || '')}"></td>` +
      `<td><input class="field" data-live="url" value="${esc(row.url || '')}" placeholder="https://…/live.m3u"></td>` +
      `<td><input class="field" data-live="sort" type="number" value="${esc(row.sort ?? i)}" style="width:64px"></td>` +
      `<td style="text-align:center"><input type="checkbox" data-live="enabled"${row.enabled === false ? '' : ' checked'}></td>` +
      `<td class="actions"><button type="button" class="btn sm danger" data-live-del>删</button></td>` +
      `</tr>`
    );
  }

  function collectLiveRows() {
    return $$('#ge_lives_body tr[data-live-row]')
      .map((tr) => {
        const get = (k) => tr.querySelector(`[data-live="${k}"]`);
        const url = (get('url')?.value || '').trim();
        const name = (get('name')?.value || '').trim();
        if (!url && !name) return null;
        return {
          id: (get('id')?.value || '').trim(),
          name: name || url,
          url,
          sort: Number(get('sort')?.value) || 0,
          enabled: !!(get('enabled') && get('enabled').checked),
        };
      })
      .filter(Boolean);
  }

  async function renderGroupEditor(g) {
    const editor = $('#grp_editor');
    editor.innerHTML = '<p class="empty">加载中…</p>';
    const [repos, sites] = await Promise.all([fetchReposForPicker(), fetchSitesForHides()]);
    const vodIds = new Set((g.vodIds || []).map(Number));
    const settings = g.settings || {};
    const hides = new Set(g.siteHides || []);
    const lives = Array.isArray(g.lives) ? g.lives : [];

    const vodChecks = repos.length
      ? repos
          .map((r) => {
            const id = Number(r.id);
            const checked = vodIds.has(id) ? ' checked' : '';
            const title = r.title || r.name || r.url || id;
            return (
              `<label><input type="checkbox" data-vod-id="${id}"${checked}>` +
              `<span><span class="ck-title">${esc(title)}</span>` +
              `<div class="ck-sub">#${esc(id)} · ${esc(r.url || '')}</div></span></label>`
            );
          })
          .join('')
      : '<div class="empty">暂无点播仓，请先在「资源池」添加</div>';

    const siteChecks = sites.length
      ? sites
          .map(
            (s) =>
              `<label><input type="checkbox" data-site-key="${esc(s.key)}"${hides.has(s.key) ? ' checked' : ''}>` +
              `<span><span class="ck-title">${esc(s.name || s.key)}</span>` +
              `<div class="ck-sub">${esc(s.key)}</div></span></label>`
          )
          .join('')
      : '';
    const knownSiteKeys = new Set(sites.map((s) => s.key));
    const extraHideText = (g.siteHides || []).filter((k) => !knownSiteKeys.has(k)).join('\n');

    const capsHtml = CAP_KEYS.map((k) => {
      // defaults: allowAddRepo / forceIncognito off；其余 on
      const defOn = !(k === 'allowAddRepo' || k === 'forceIncognito');
      const checked = settings[k] !== undefined ? truthyStr(settings[k]) : defOn;
      return `<label class="check"><input type="checkbox" data-cap="${k}"${checked ? ' checked' : ''}> ${esc(CAP_LABELS[k] || k)}</label>`;
    }).join('');

    const extraHtml = EXTRA_SETTING_KEYS.map(
      ([k, label]) =>
        `<label class="block"><span>${esc(label)}</span>` +
        `<input class="field" data-setting="${k}" value="${esc(settings[k] || '')}"></label>`
    ).join('');

    const liveRowsHtml = (lives.length
      ? lives
          .map((l, i) => liveRowHtml(l, i))
          .join('')
      : '') ;

    editor.innerHTML = `
      <div class="row" style="justify-content:space-between;margin-top:0">
        <h3 style="margin:0">${esc(g.name)}</h3>
        <div class="row" style="margin:0">
          <button class="btn ghost sm" type="button" id="btn_grp_export">导出</button>
          <button class="btn ghost sm" type="button" id="btn_grp_import">导入</button>
          <button class="btn ghost sm" type="button" id="btn_grp_copy">复制为新组</button>
          <button class="btn danger sm" type="button" id="btn_grp_del">删除</button>
        </div>
      </div>
      <p class="hint">ID: ${esc(g.id)}</p>
      <div class="form-grid">
        <label class="block"><span>名称</span><input class="field" id="ge_name" value="${esc(g.name)}"></label>
        <label class="block"><span>备注</span><input class="field" id="ge_note" value="${esc(g.note || '')}"></label>
        <label class="block"><span>排序</span><input class="field" id="ge_sort" type="number" value="${esc(g.sort ?? 0)}"></label>
        <label class="block" style="flex-direction:row;align-items:center;padding-top:22px">
          <label class="check"><input type="checkbox" id="ge_enabled"${g.enabled === false ? '' : ' checked'}> 启用</label>
        </label>
      </div>
      <div class="row"><button class="btn sm" type="button" id="btn_ge_meta">保存基本信息</button></div>

      <h3 style="margin-top:18px">点播仓</h3>
      <div class="check-grid" id="ge_vods">${vodChecks}</div>
      <div class="row"><button class="btn sm" type="button" id="btn_ge_vods">保存点播勾选</button></div>

      <h3 style="margin-top:18px">分组直播列表</h3>
      <p class="hint">本组用户看到的直播源（覆盖点播仓里自带的 lives）。名称 + 地址；保存后对该组立即生效。</p>
      <div class="table-scroll">
        <table class="data" id="ge_lives_table">
          <thead><tr><th style="width:28%">名称</th><th>地址</th><th style="width:70px">排序</th><th style="width:70px">启用</th><th style="width:70px"></th></tr></thead>
          <tbody id="ge_lives_body">${liveRowsHtml}</tbody>
        </table>
      </div>
      <div class="row">
        <button class="btn ghost sm" type="button" id="btn_ge_live_add">添加一行</button>
        <button class="btn sm" type="button" id="btn_ge_lives">保存直播列表</button>
      </div>

      <h3 style="margin-top:18px">能力开关</h3>
      <div class="caps-grid" id="ge_caps">${capsHtml}</div>

      <h3 style="margin-top:18px">其它设置</h3>
      <div class="form-grid" id="ge_extra">${extraHtml}</div>
      <div class="row"><button class="btn sm" type="button" id="btn_ge_settings">保存设置</button></div>

      <h3 style="margin-top:18px">隐藏站点</h3>
      ${
        siteChecks
          ? `<div class="check-grid" id="ge_sites">${siteChecks}</div>`
          : `<p class="hint">当前无站点列表时可手填 key（逗号或换行分隔）</p>`
      }
      <textarea class="field" id="ge_hides_text" placeholder="额外 key，逗号或换行">${esc(siteChecks ? extraHideText : (g.siteHides || []).join('\n'))}</textarea>
      <div class="row"><button class="btn sm" type="button" id="btn_ge_hides">保存隐藏站</button></div>
    `;

    $('#btn_ge_meta').onclick = async () => {
      try {
        await post('/api/v1/admin/groups', {
          id: g.id,
          name: $('#ge_name').value.trim(),
          note: $('#ge_note').value.trim(),
          sort: Number($('#ge_sort').value) || 0,
          enabled: $('#ge_enabled').checked,
        });
        toast('已保存基本信息');
        await refreshGroups();
      } catch (e) {
        toast(e.message);
      }
    };

    $('#btn_ge_vods').onclick = async () => {
      const ids = $$('#ge_vods input[data-vod-id]:checked').map((el) => Number(el.dataset.vodId));
      try {
        await put('/api/v1/admin/groups/' + encodeURIComponent(g.id) + '/vods', { configIds: ids });
        toast('点播仓已保存');
        await refreshGroups();
      } catch (e) {
        toast(e.message);
      }
    };

    const bindLiveRowDel = () => {
      $$('#ge_lives_body [data-live-del]').forEach((btn) => {
        btn.onclick = () => {
          const tr = btn.closest('tr');
          if (tr) tr.remove();
        };
      });
    };
    bindLiveRowDel();
    $('#btn_ge_live_add').onclick = () => {
      const body = $('#ge_lives_body');
      const i = $$('#ge_lives_body tr[data-live-row]').length;
      body.insertAdjacentHTML('beforeend', liveRowHtml({ sort: i, enabled: true }, i));
      bindLiveRowDel();
    };
    $('#btn_ge_lives').onclick = async () => {
      try {
        const livesBody = collectLiveRows();
        await put('/api/v1/admin/groups/' + encodeURIComponent(g.id) + '/lives', { lives: livesBody });
        toast('直播列表已保存（' + livesBody.length + ' 条）');
        await refreshGroups();
      } catch (e) {
        toast(e.message);
      }
    };

    $('#btn_ge_settings').onclick = async () => {
      const map = {};
      $$('#ge_caps input[data-cap]').forEach((el) => {
        map[el.dataset.cap] = el.checked ? 'true' : 'false';
      });
      $$('#ge_extra input[data-setting]').forEach((el) => {
        map[el.dataset.setting] = el.value.trim();
      });
      try {
        await put('/api/v1/admin/groups/' + encodeURIComponent(g.id) + '/settings', map);
        toast('设置已保存');
        await refreshGroups();
      } catch (e) {
        toast(e.message);
      }
    };

    $('#btn_ge_hides').onclick = async () => {
      const keys = new Set();
      $$('#ge_sites input[data-site-key]:checked').forEach((el) => keys.add(el.dataset.siteKey));
      String($('#ge_hides_text').value || '')
        .split(/[\s,，;；]+/)
        .map((s) => s.trim())
        .filter(Boolean)
        .forEach((k) => keys.add(k));
      try {
        await put('/api/v1/admin/groups/' + encodeURIComponent(g.id) + '/siteHides', {
          keys: Array.from(keys),
        });
        toast('隐藏站已保存');
        await refreshGroups();
      } catch (e) {
        toast(e.message);
      }
    };

    $('#btn_grp_del').onclick = async () => {
      if (!confirm('删除分组「' + g.name + '」？')) return;
      try {
        await del('/api/v1/admin/groups/' + encodeURIComponent(g.id));
        state.selectedGroupId = null;
        toast('已删除');
        await refreshGroups();
      } catch (e) {
        toast(e.message);
      }
    };

    $('#btn_grp_copy').onclick = async () => {
      const name = prompt('新分组名称', g.name + ' 副本');
      if (!name) return;
      try {
        const res = await post('/api/v1/admin/groups', { name, copyOf: g.id });
        state.selectedGroupId = res.id || null;
        toast('已复制');
        await refreshGroups();
      } catch (e) {
        toast(e.message);
      }
    };

    $('#btn_grp_export').onclick = async () => {
      try {
        const data = await api('/api/v1/admin/groups/' + encodeURIComponent(g.id) + '/export');
        const blob = new Blob([JSON.stringify(data.group || data, null, 2)], {
          type: 'application/json',
        });
        const a = document.createElement('a');
        a.href = URL.createObjectURL(blob);
        a.download = 'group-' + g.id + '.json';
        a.click();
        URL.revokeObjectURL(a.href);
        toast('已导出');
      } catch (e) {
        toast(e.message);
      }
    };

    $('#btn_grp_import').onclick = async () => {
      const raw = prompt('粘贴分组导出 JSON（含 vodIds/lives/settings/siteHides）');
      if (!raw) return;
      try {
        let body = JSON.parse(raw);
        if (body.group) body = body.group;
        await post('/api/v1/admin/groups/' + encodeURIComponent(g.id) + '/import', {
          vodIds: body.vodIds || body.configIds || [],
          lives: body.lives || [],
          settings: body.settings || {},
          siteHides: body.siteHides || [],
        });
        toast('已导入');
        await refreshGroups();
      } catch (e) {
        toast(e.message);
      }
    };
  }

  /* ========== Users ========== */
  function renderPendingApprovals(users) {
    const box = $('#pending_approvals');
    if (!box) return;
    const pending = (users || []).filter((u) => (u.status || '') === 'pending');
    if (!pending.length) {
      box.innerHTML = '<p class="empty" style="margin:0">暂无待审批账号</p>';
      return;
    }
    box.innerHTML = '';
    pending.forEach((u) => {
      const row = document.createElement('div');
      row.className = 'row';
      row.style.margin = '0 0 8px';
      row.innerHTML =
        `<div style="flex:1"><strong>${esc(u.username)}</strong>` +
        `<span class="hint" style="margin-left:8px">分组 ${esc(u.groupId || 'default')}</span></div>`;
      const btn = document.createElement('button');
      btn.type = 'button';
      btn.className = 'btn sm';
      btn.textContent = '通过审批';
      btn.onclick = async () => {
        try {
          await post('/api/v1/admin/users/' + u.id + '/approve');
          toast('已审批 ' + u.username);
          refreshUsers();
        } catch (e) {
          toast(e.message);
        }
      };
      row.appendChild(btn);
      box.appendChild(row);
    });
  }

  async function refreshUsers() {
    await loadGroups();
    const data = await api('/api/v1/admin/users');
    state.users = data.users || [];
    renderPendingApprovals(state.users);
    const pendingCard = $('#card_pending');
    if (pendingCard) {
      const show =
        truthyStr(data.requireApproval) ||
        truthyStr(data.allowRegister) ||
        state.users.some((u) => (u.status || '') === 'pending');
      pendingCard.classList.toggle('hidden', !show);
    }
    const tb = $('#user_rows');
    tb.innerHTML = '';
    const devSel = $('#dev_user');
    const prevDev = devSel ? devSel.value : '';
    if (devSel) {
      devSel.innerHTML =
        '<option value="">选择用户…</option>' +
        state.users
          .map((u) => `<option value="${esc(u.id)}">${esc(u.username)}</option>`)
          .join('');
      if (prevDev) devSel.value = prevDev;
    }
    if (!state.users.length) {
      tb.innerHTML = '<tr><td colspan="5" class="empty">暂无用户</td></tr>';
      return;
    }
    state.users.forEach((u) => {
      const tr = document.createElement('tr');
      const groupOpts = state.groups
        .map(
          (g) =>
            `<option value="${esc(g.id)}"${g.id === u.groupId ? ' selected' : ''}>${esc(g.name)}</option>`
        )
        .join('');
      const role = u.role === 'admin' ? 'admin' : 'user';
      const st = u.status || (u.enabled ? 'active' : 'disabled');
      const stBadge =
        st === 'pending'
          ? '<span class="badge warn">待审批</span>'
          : u.enabled
            ? '<span class="badge">启用</span>'
            : '<span class="badge danger">禁用</span>';
      tr.innerHTML =
        `<td>${esc(u.username)}</td>` +
        `<td><select class="field" data-role-for="${esc(u.id)}" style="min-width:90px">` +
        `<option value="user"${role === 'user' ? ' selected' : ''}>${ROLE_LABELS.user}</option>` +
        `<option value="admin"${role === 'admin' ? ' selected' : ''}>${ROLE_LABELS.admin}</option>` +
        `</select></td>` +
        `<td><select class="field" data-group-for="${esc(u.id)}" style="min-width:110px">${groupOpts}</select></td>` +
        `<td>${stBadge}</td>` +
        `<td class="actions"></td>`;
      const actions = tr.querySelector('.actions');
      const roleSel = tr.querySelector('select[data-role-for]');
      const sel = tr.querySelector('select[data-group-for]');
      roleSel.onchange = async () => {
        try {
          await post('/api/v1/admin/users/' + u.id + '/role', { role: roleSel.value });
          toast('角色已更新');
        } catch (e) {
          toast(e.message);
          refreshUsers();
        }
      };
      sel.onchange = async () => {
        try {
          await post('/api/v1/admin/users/' + u.id + '/group', { groupId: sel.value });
          toast('分组已更新');
        } catch (e) {
          toast(e.message);
          refreshUsers();
        }
      };

      const mk = (label, cls, fn) => {
        const b = document.createElement('button');
        b.type = 'button';
        b.className = 'btn sm ' + (cls || 'ghost');
        b.textContent = label;
        b.onclick = fn;
        actions.appendChild(b);
      };
      mk('设备', 'ghost', () => {
        if (devSel) {
          devSel.value = u.id;
          loadUserDevices(u.id);
        }
      });
      if (st === 'pending') {
        mk('审批', '', async () => {
          try {
            await post('/api/v1/admin/users/' + u.id + '/approve');
            toast('已审批');
            refreshUsers();
          } catch (e) {
            toast(e.message);
          }
        });
      }
      mk(u.enabled ? '禁用' : '启用', 'ghost', async () => {
        try {
          await post('/api/v1/admin/users/' + u.id + '/' + (u.enabled ? 'disable' : 'enable'));
          refreshUsers();
        } catch (e) {
          toast(e.message);
        }
      });
      mk('重置密码', 'ghost', async () => {
        const p = prompt('新密码');
        if (!p) return;
        try {
          await kotvAuth.postSealed('/api/v1/admin/users/' + u.id + '/password', { password: p });
          toast('已重置');
        } catch (e) {
          toast(e.message);
        }
      });
      mk('强制登出', 'ghost', async () => {
        try {
          await post('/api/v1/admin/users/' + u.id + '/logout');
          toast('已强制登出');
        } catch (e) {
          toast(e.message);
        }
      });
      mk('删除', 'danger', async () => {
        if (!confirm('删除 ' + u.username + '？')) return;
        try {
          await del('/api/v1/admin/users/' + u.id);
          refreshUsers();
        } catch (e) {
          toast(e.message);
        }
      });
      tb.appendChild(tr);
    });
    if (devSel && devSel.value) {
      loadUserDevices(devSel.value).catch(() => {});
    }
  }

  async function loadUserDevices(userId) {
    const el = $('#dev_list');
    if (!el) return;
    if (!userId) {
      el.innerHTML = '<div class="empty">选择用户以加载设备</div>';
      return;
    }
    el.innerHTML = '<div class="empty">加载中…</div>';
    try {
      const data = await api('/api/v1/admin/users/' + encodeURIComponent(userId) + '/devices');
      const list = data.devices || [];
      if (!list.length) {
        el.innerHTML = '<div class="empty">该用户暂无绑定设备</div>';
        return;
      }
      el.innerHTML = wrapTable(
        '<table class="data"><thead><tr><th>设备</th><th>客户端 ID</th><th>最近活跃</th><th></th></tr></thead><tbody></tbody></table>'
      );
      const tb = $('tbody', el);
      list.forEach((d) => {
        const tr = document.createElement('tr');
        const cid = d.clientId || d.client_id || '';
        tr.innerHTML =
          `<td>${esc(d.name || '—')}</td>` +
          `<td class="cell-wrap"><code>${esc(cid)}</code></td>` +
          `<td>${esc(fmtTime(d.lastSeen || d.last_seen || d.createdAt))}</td>` +
          `<td class="actions"></td>`;
        const b = document.createElement('button');
        b.type = 'button';
        b.className = 'btn sm danger';
        b.textContent = '解绑';
        b.onclick = async () => {
          if (!confirm('解绑该设备？')) return;
          try {
            await del(
              '/api/v1/admin/users/' +
                encodeURIComponent(userId) +
                '/devices?clientId=' +
                encodeURIComponent(cid)
            );
            toast('已解绑');
            loadUserDevices(userId);
          } catch (e) {
            toast(e.message);
          }
        };
        tr.querySelector('.actions').appendChild(b);
        tb.appendChild(tr);
      });
    } catch (e) {
      el.innerHTML = '<div class="empty">' + esc(e.message) + '</div>';
    }
  }

  /* ========== Repos ========== */
  function buildLoadMap(rows) {
    const map = {};
    (rows || []).forEach((r) => {
      const id = String(r.refId || '').trim();
      const name = String(r.refName || '').trim();
      if (id) map[id] = r.count;
      if (name) map[name] = r.count;
    });
    return map;
  }

  async function refreshRepos() {
    ensureRepoPanel();
    const to = Date.now();
    const from = new Date().setHours(0, 0, 0, 0);
    const q = 'from=' + from + '&to=' + to;
    const kind = $('#repo_kind')?.value || 'vod';
    try {
      const data = await api(
        kind === 'live'
          ? '/api/v1/admin/stats/lives?' + q
          : '/api/v1/admin/stats/repos?' + q
      );
      state.repoLoadMap = buildLoadMap(data.rows);
    } catch (_) {
      state.repoLoadMap = {};
    }
    if (state.repoPanel) await state.repoPanel.refresh();
    else paintRepoBadges();
  }

  function paintRepoBadges() {
    const list = $('#admin_repo_list');
    if (!list) return;
    $$('.repo-item', list).forEach((row) => {
      const url = $('.file-time', row)?.getAttribute('title') || $('.file-time', row)?.textContent || '';
      const name = ($('.file-name', row)?.textContent || '').replace(/当前$/, '').trim();
      const count = state.repoLoadMap[url] ?? state.repoLoadMap[name];
      let badge = row.querySelector('.repo-load-badge');
      if (count == null) {
        if (badge) badge.remove();
        return;
      }
      if (!badge) {
        badge = document.createElement('span');
        badge.className = 'repo-load-badge';
        const nameEl = $('.file-name', row);
        if (nameEl) nameEl.appendChild(badge);
      }
      badge.textContent = '今日 ' + count;
    });
  }

  function ensureRepoPanel() {
    if (state.repoPanel || !window.kotvRepos) return;
    state.repoPanel = kotvRepos.bindPanel({
      kindSelect: $('#repo_kind'),
      urlInput: $('#repo_url'),
      nameInput: $('#repo_name'),
      listEl: $('#admin_repo_list'),
      addBtn: $('#btn_repo_add'),
      refreshBtn: $('#btn_repo_refresh'),
      onToast: toast,
    });
    const inner = state.repoPanel.refresh;
    state.repoPanel.refresh = async () => {
      await inner();
      paintRepoBadges();
    };
    $('#repo_kind')?.addEventListener('change', () => {
      if (state.currentView === 'repos') {
        refreshRepos().catch((e) => toast(e.message));
      }
    });
  }

  /* ========== Messages ========== */
  function renderPushLogs(logs) {
    const el = $('#push_logs');
    if (!el) return;
    if (!logs || !logs.length) {
      el.innerHTML = '<div class="empty">暂无推送记录</div>';
      return;
    }
    el.innerHTML = wrapTable(
      '<table class="data"><thead><tr><th>时间</th><th>操作者</th><th>目标</th><th>类型</th><th>内容</th></tr></thead><tbody>' +
        logs
          .slice(0, 40)
          .map((p) => {
            let detail = '';
            try {
              const payload = typeof p.payload === 'string' ? JSON.parse(p.payload) : p.payload;
              if (payload) {
                detail = [payload.name, payload.site, payload.id, payload.url].filter(Boolean).join(' · ');
              }
            } catch (_) {
              detail = String(p.payload || '').slice(0, 80);
            }
            return (
              `<tr><td>${esc(fmtTime(p.at))}</td><td>${esc(fmtActor(p.actor))}</td>` +
              `<td class="cell-wrap">${esc(p.target || '—')}</td>` +
              `<td>${esc(labelOf(PUSH_KIND_LABELS, p.kind, p.kind || '—'))}</td>` +
              `<td class="cell-wrap" title="${esc(detail)}">${esc((detail || '—').slice(0, 60))}</td></tr>`
            );
          })
          .join('') +
        '</tbody></table>'
    );
  }

  async function refreshPushLogs() {
    try {
      const data = await api('/api/v1/admin/push/logs?limit=50');
      renderPushLogs(data.logs || []);
    } catch (e) {
      const el = $('#push_logs');
      if (el) el.innerHTML = `<div class="empty">${esc(e.message || '加载失败')}</div>`;
    }
  }

  async function refreshMessages() {
    await loadGroups();
    await ensureUsers();
    fillGroupSelects();
    fillUserSelects();
    syncNoticeTargetOptions($('#nt_target')?.value || '');
    const [data] = await Promise.all([
      api('/api/v1/admin/notices'),
      refreshPushLogs(),
    ]);
    const list = data.notices || [];
    const el = $('#nt_list');
    if (!list.length) {
      el.innerHTML = '<div class="empty">暂无公告</div>';
      return;
    }
    el.innerHTML = wrapTable(
      '<table class="data"><thead><tr><th>标题</th><th>范围</th><th>排期</th><th>确认</th><th>操作</th></tr></thead><tbody></tbody></table>'
    );
    const tb = $('tbody', el);
    list.forEach((n) => {
      const tr = document.createElement('tr');
      const schedule =
        (n.startsAt || n.endsAt
          ? `${n.startsAt ? fmtTime(n.startsAt) : '即刻'} → ${n.endsAt ? fmtTime(n.endsAt) : '长期'}`
          : '长期有效');
      tr.innerHTML =
        `<td class="cell-wrap">${esc(n.title)}${n.sticky ? ' <span class="badge warn">置顶</span>' : ''}` +
        ` <span class="badge muted">${esc(labelOf(NOTICE_KIND_LABELS, n.kind, n.kind))}</span>` +
        `<div style="font-size:.75rem;color:var(--admin-muted)">${esc((n.body || '').slice(0, 80))}</div>` +
        (n.link
          ? `<div style="font-size:.72rem;color:var(--admin-accent)">${esc(n.link)}</div>`
          : '') +
        `<div style="font-size:.7rem;color:var(--admin-muted)">${esc(fmtTime(n.createdAt))} · ${esc(fmtActor(n.createdBy))}</div></td>` +
        `<td>${esc(labelOf(SCOPE_LABELS, n.scope, n.scope))}${n.targetId ? ' / ' + esc(n.targetId) : ''}` +
        (n.priority ? `<div class="badge muted">P${esc(n.priority)}</div>` : '') +
        `</td>` +
        `<td style="font-size:.78rem">${esc(schedule)}</td>` +
        `<td>${n.sticky ? esc(n.ackCount ?? 0) : '—'}</td>` +
        `<td class="actions"></td>`;
      const editBtn = document.createElement('button');
      editBtn.type = 'button';
      editBtn.className = 'btn sm ghost';
      editBtn.textContent = '编辑';
      editBtn.onclick = () => {
        fillNoticeForm(n);
        $('#nt_title')?.scrollIntoView({ behavior: 'smooth', block: 'center' });
      };
      const delBtn = document.createElement('button');
      delBtn.type = 'button';
      delBtn.className = 'btn sm danger';
      delBtn.textContent = '删除';
      delBtn.onclick = async () => {
        if (!confirm('删除公告？')) return;
        try {
          await del('/api/v1/admin/notices?id=' + encodeURIComponent(n.id));
          toast('已删除');
          if ($('#nt_id')?.value === n.id) resetNoticeForm();
          refreshMessages();
        } catch (e) {
          toast(e.message);
        }
      };
      tr.querySelector('.actions').append(editBtn, delBtn);
      tb.appendChild(tr);
    });
  }

  /* ========== Security ========== */
  async function refreshSecurity() {
    await loadGroups();
    fillGroupSelects();
    const [usersData, cs, invites] = await Promise.all([
      api('/api/v1/admin/users').catch(() => ({})),
      loadConsoleSettings(),
      api('/api/v1/admin/invites'),
    ]);
    $('#opt_register').checked = !!(cs.allowRegister ?? usersData.allowRegister);
    if ($('#opt_invite')) $('#opt_invite').checked = truthyStr(cs.requireInvite);
    if ($('#opt_approval')) $('#opt_approval').checked = truthyStr(cs.requireApproval);
    if ($('#sec_ip_allow')) $('#sec_ip_allow').value = cs.ipAllow || '';
    if ($('#sec_ip_deny')) $('#sec_ip_deny').value = cs.ipDeny || '';
    if ($('#sec_hours')) $('#sec_hours').value = cs.accessHours || '';

    const list = invites.invites || [];
    const el = $('#inv_list');
    if (!list.length) {
      el.innerHTML = '<div class="empty">暂无邀请码</div>';
      return;
    }
    el.innerHTML = wrapTable(
      '<table class="data"><thead><tr><th>码</th><th>分组</th><th>使用</th><th>过期</th><th></th></tr></thead><tbody></tbody></table>'
    );
    const tb = $('tbody', el);
    list.forEach((inv) => {
      const tr = document.createElement('tr');
      tr.innerHTML =
        `<td><code>${esc(inv.code)}</code></td>` +
        `<td>${esc(groupName(inv.groupId))}</td>` +
        `<td>${esc(inv.used)} / ${esc(inv.maxUses)}</td>` +
        `<td>${inv.expiresAt ? esc(fmtTime(inv.expiresAt)) : '永不过期'}</td>` +
        `<td class="actions"></td>`;
      const b = document.createElement('button');
      b.type = 'button';
      b.className = 'btn sm danger';
      b.textContent = '删除';
      b.onclick = async () => {
        try {
          await del('/api/v1/admin/invites?code=' + encodeURIComponent(inv.code));
          toast('已删除');
          refreshSecurity();
        } catch (e) {
          toast(e.message);
        }
      };
      tr.querySelector('.actions').appendChild(b);
      tb.appendChild(tr);
    });
  }

  /* ========== Ops ========== */
  function renderAuditTable(el, rows) {
    if (!rows || !rows.length) {
      el.innerHTML = '<div class="empty">暂无审计</div>';
      return;
    }
    el.innerHTML = wrapTable(
      '<table class="data"><thead><tr><th>时间</th><th>操作者</th><th>动作</th><th>目标</th><th>详情</th></tr></thead><tbody>' +
        rows
          .map(
            (a) =>
              `<tr><td>${esc(fmtTime(a.at))}</td><td>${esc(fmtActor(a.actor))}</td>` +
              `<td>${esc(fmtAuditAction(a.action))}</td>` +
              `<td class="cell-wrap" title="${esc(a.target || '')}">${esc(a.target || '—')}</td>` +
              `<td class="cell-wrap">${esc(a.detail || '')}</td></tr>`
          )
          .join('') +
        '</tbody></table>'
    );
  }

  async function refreshLogs(keepSelection) {
    const sel = $('#log_file');
    const view = $('#log_view');
    const meta = $('#log_meta');
    if (!sel || !view) return;
    const prev = keepSelection ? sel.value : '';
    const data = await api('/api/v1/admin/logs');
    const files = data.files || [];
    sel.innerHTML =
      '<option value="">选择日志…</option>' +
      files
        .map(
          (f) =>
            `<option value="${esc(f.name)}">${esc(f.name)} · ${fmtBytes(f.size)}</option>`
        )
        .join('');
    if (prev && files.some((f) => f.name === prev)) sel.value = prev;
    else if (!prev && files.some((f) => f.name === 'kotv.log')) sel.value = 'kotv.log';
    meta.textContent = '目录 ' + (data.dir || '—') + ' · ' + files.length + ' 个文件';
    if (sel.value) await loadLogTail(sel.value);
    else view.textContent = files.length ? '选择日志文件后显示内容' : '暂无日志文件';
  }

  async function loadLogTail(name) {
    const view = $('#log_view');
    const meta = $('#log_meta');
    if (!view || !name) return;
    const data = await api('/api/v1/admin/logs?name=' + encodeURIComponent(name) + '&tail=' + 196608);
    view.textContent = data.content || '（空）';
    if (meta) {
      meta.textContent =
        name + ' · ' + fmtBytes(data.size) + ' · 显示末尾 ' + fmtBytes((data.content || '').length);
    }
    view.scrollTop = view.scrollHeight;
  }

  async function clearLogs(name) {
    const body = name ? { action: 'clear', name } : { action: 'clear' };
    const res = await post('/api/v1/admin/logs', body);
    toast('已清理，释放 ' + fmtBytes(res.freedBytes));
    await refreshLogs(true);
  }

  async function refreshOps() {
    const cs = await loadConsoleSettings();
    $('#ops_maintenance').checked = truthyStr(cs.maintenance);
    $('#ops_force').checked = truthyStr(cs.forceUpdate);
    $('#ops_maint_msg').value = cs.maintenanceMsg || '';
    $('#ops_min_ver').value = cs.minClientVersion || '';
    $('#ops_retention').value = cs.usageRetentionDays || '';
    if ($('#ops_max_devices')) $('#ops_max_devices').value = cs.maxDevices || '';
    if ($('#ops_max_sessions')) $('#ops_max_sessions').value = cs.maxSessions || '';
    const data = await api('/api/v1/admin/audit');
    renderAuditTable($('#audit_list'), data.audit || []);
    try {
      await refreshLogs(true);
    } catch (e) {
      if ($('#log_meta')) $('#log_meta').textContent = e.message || '日志加载失败';
    }
  }

  /* ========== Settings ========== */
  async function refreshSettings() {
    await loadGroups();
    const cs = await loadConsoleSettings();
    fillGroupSelects();
    $('#set_update_url').value = cs.updateUrl || '';
    if (cs.defaultGroupId) $('#set_default_group').value = cs.defaultGroupId;
    $('#brand_logo').value = cs.logo || '';
    $('#brand_wallpaper').value = cs.wallpaper || '';
    $('#brand_banner').value = cs.banner || '';
    $('#brand_about').value = cs.aboutUrl || '';
    $('#brand_support').value = cs.supportUrl || '';
    $('#brand_footer').value = cs.footer || '';
    $('#brand_welcome').value = cs.welcome || '';
  }

  /* ========== Enter / Login ========== */
  async function enter() {
    let authState;
    try {
      authState = await kotvAuth.check(true);
    } catch (_) {
      return showPanel(false, '无法连接主机');
    }
    if (authState === 'denied') {
      return showPanel(false, '无法访问：请在本机打开，或使用管理员账号从已开放的入口登录');
    }
    if (authState !== 'ok') {
      showPanel(false);
      if (authState === 'notAdmin') {
        $('#login_hint').textContent = '仅本机或管理员可进入管理台，请换管理员账号登录';
      } else {
        $('#login_hint').textContent = '非本机访问须管理员登录。新装默认 admin / admin';
      }
      return;
    }
    $('#btn_logout').classList.toggle('hidden', !kotvAuth.hasToken());
    showPanel(true);
    try {
      await loadGroups();
      await loadConsoleSettings();
      ensureRepoPanel();
      showView(state.currentView || 'overview');
    } catch (e) {
      toast(e.message);
    }
  }

  async function login() {
    try {
      const data = await kotvAuth.login($('#login_user').value.trim(), $('#login_pass').value);
      $('#login_pass').value = '';
      if (data.user && data.user.mustChangePassword) toast('请尽快修改默认密码');
      await enter();
    } catch (e) {
      toast(e.message);
    }
  }

  /* ========== Wire events ========== */
  function bind() {
    $('#btn_login').onclick = login;
    $('#login_pass').addEventListener('keydown', (ev) => {
      if (ev.key === 'Enter') login();
    });
    $('#btn_logout').onclick = async () => {
      await kotvAuth.logout();
      enter();
    };
    $('#menu_toggle').onclick = () => setSidebarOpen(!$('#sidebar').classList.contains('open'));
    $('#scrim').onclick = () => setSidebarOpen(false);

    $$('#nav button').forEach((btn) => {
      btn.onclick = () => showView(btn.dataset.view);
    });

    $$('#range_seg button').forEach((btn) => {
      btn.onclick = () => {
        $$('#range_seg button').forEach((b) => b.classList.remove('active'));
        btn.classList.add('active');
        state.rangeDays = Number(btn.dataset.range) || 1;
        refreshOverview().catch((e) => toast(e.message));
      };
    });
    $('#btn_ov_refresh').onclick = () => refreshOverview().catch((e) => toast(e.message));
    $('#btn_ov_system') &&
      ($('#btn_ov_system').onclick = () => refreshOverview().catch((e) => toast(e.message)));
    $('#ov_group').onchange = () => refreshOverview().catch((e) => toast(e.message));
    $('#ov_platform').onchange = () => refreshOverview().catch((e) => toast(e.message));
    if ($('#dev_user')) {
      $('#dev_user').onchange = () => {
        loadUserDevices($('#dev_user').value).catch((e) => toast(e.message));
      };
    }

    $('#btn_grp_create').onclick = async () => {
      const name = $('#grp_new_name').value.trim();
      if (!name) return toast('请填写分组名称');
      try {
        const body = {
          name,
          note: $('#grp_new_note').value.trim(),
        };
        const copyOf = $('#grp_copy_of').value;
        if (copyOf) body.copyOf = copyOf;
        const res = await post('/api/v1/admin/groups', body);
        $('#grp_new_name').value = '';
        $('#grp_new_note').value = '';
        state.selectedGroupId = res.id || null;
        toast('已创建');
        await refreshGroups();
      } catch (e) {
        toast(e.message);
      }
    };

    $('#btn_create').onclick = async () => {
      try {
        await kotvAuth.postSealed('/api/v1/admin/users', {
          username: $('#new_user').value.trim(),
          password: $('#new_pass').value,
          role: $('#new_role').value,
          groupId: $('#new_group').value,
        });
        $('#new_user').value = '';
        $('#new_pass').value = '';
        await refreshUsers();
        toast('已创建');
      } catch (e) {
        toast(e.message);
      }
    };

    $('#nt_scope') &&
      ($('#nt_scope').onchange = () => syncNoticeTargetOptions(''));
    $('#btn_nt_cancel') &&
      ($('#btn_nt_cancel').onclick = () => resetNoticeForm());
    $('#btn_nt_save').onclick = async () => {
      try {
        const scope = $('#nt_scope').value;
        const targetId = $('#nt_target').value.trim();
        if (scope !== 'all' && !targetId) {
          return toast(scope === 'group' ? '请选择目标分组' : '请选择目标用户');
        }
        const body = {
          id: ($('#nt_id')?.value || '').trim(),
          title: $('#nt_title').value.trim(),
          body: $('#nt_body').value.trim(),
          kind: $('#nt_kind').value,
          scope,
          targetId: scope === 'all' ? '' : targetId,
          link: $('#nt_link').value.trim(),
          sticky: $('#nt_sticky').checked,
          priority: Number($('#nt_priority').value) || 0,
          startsAt: localInputToMs($('#nt_starts')),
          endsAt: localInputToMs($('#nt_ends')),
        };
        if (!body.title) return toast('请填写标题');
        await post('/api/v1/admin/notices', body);
        toast(body.id ? '已保存' : '已发布');
        resetNoticeForm();
        await refreshMessages();
      } catch (e) {
        toast(e.message);
      }
    };

    $('#btn_push_logs') &&
      ($('#btn_push_logs').onclick = () => refreshPushLogs().catch((e) => toast(e.message)));

    $('#btn_push').onclick = async () => {
      try {
        const groupId = $('#push_group').value;
        const userId = ($('#push_user').value || '').trim();
        if (!groupId && !userId) {
          if (!confirm('未指定分组/用户，将广播到默认队列。确定继续？')) return;
        }
        const res = await post('/api/v1/admin/push/open', {
          groupId,
          userId,
          kind: $('#push_kind').value,
          site: $('#push_site').value.trim(),
          id: $('#push_id').value.trim(),
          name: $('#push_name').value.trim(),
          url: $('#push_url').value.trim(),
          emergency: $('#push_emergency').checked,
        });
        const n = res.targets;
        toast(n < 0 ? '已广播推送' : '已推送，目标数 ' + (n ?? '—'));
        await refreshPushLogs();
      } catch (e) {
        toast(e.message);
      }
    };

    $('#btn_save_opts').onclick = async () => {
      try {
        const allowRegister = $('#opt_register').checked;
        let requireApproval = $('#opt_approval') ? $('#opt_approval').checked : false;
        if (allowRegister && $('#opt_approval') && !requireApproval) {
          // 开放注册时默认勾选审批，避免自助账号直接可用。
          $('#opt_approval').checked = true;
          requireApproval = true;
        }
        await post('/api/v1/admin/console-settings', {
          allowRegister,
          requireInvite: $('#opt_invite') ? $('#opt_invite').checked : false,
          requireApproval,
        });
        try {
          await post('/api/v1/admin/settings', {
            allowRegister,
            requireApproval,
          });
        } catch (_) { /* ignore */ }
        toast('已保存');
        if (state.currentView === 'users') refreshUsers();
      } catch (e) {
        toast(e.message);
      }
    };
    if ($('#btn_save_access')) {
      $('#btn_save_access').onclick = async () => {
        try {
          await post('/api/v1/admin/console-settings', {
            ipAllow: $('#sec_ip_allow').value.trim(),
            ipDeny: $('#sec_ip_deny').value.trim(),
            accessHours: $('#sec_hours').value.trim(),
          });
          toast('准入规则已保存');
        } catch (e) {
          toast(e.message);
        }
      };
    }

    $('#btn_inv_create').onclick = async () => {
      try {
        let expiresAt = 0;
        const expVal = $('#inv_exp').value;
        if (expVal) expiresAt = new Date(expVal).getTime();
        const res = await post('/api/v1/admin/invites', {
          code: $('#inv_code').value.trim(),
          groupId: $('#inv_group').value,
          maxUses: Number($('#inv_max').value) || 1,
          expiresAt,
        });
        $('#inv_code').value = '';
        toast('邀请码 ' + (res.code || '已创建'));
        await refreshSecurity();
      } catch (e) {
        toast(e.message);
      }
    };

    $('#btn_ops_save').onclick = async () => {
      try {
        await post('/api/v1/admin/console-settings', {
          maintenance: $('#ops_maintenance').checked,
          forceUpdate: $('#ops_force').checked,
          maintenanceMsg: $('#ops_maint_msg').value.trim(),
          minClientVersion: $('#ops_min_ver').value.trim(),
          usageRetentionDays: String($('#ops_retention').value.trim()),
          maxDevices: String(($('#ops_max_devices') && $('#ops_max_devices').value.trim()) || ''),
          maxSessions: String(($('#ops_max_sessions') && $('#ops_max_sessions').value.trim()) || ''),
        });
        toast('运维设置已保存');
      } catch (e) {
        toast(e.message);
      }
    };
    $('#btn_audit_refresh').onclick = () => refreshOps().catch((e) => toast(e.message));
    if ($('#log_file')) {
      $('#log_file').onchange = () => {
        const name = $('#log_file').value;
        if (!name) return;
        loadLogTail(name).catch((e) => toast(e.message));
      };
    }
    if ($('#btn_log_refresh')) {
      $('#btn_log_refresh').onclick = () => refreshLogs(true).catch((e) => toast(e.message));
    }
    if ($('#btn_log_clear_one')) {
      $('#btn_log_clear_one').onclick = async () => {
        const name = $('#log_file') && $('#log_file').value;
        if (!name) return toast('请先选择日志文件');
        if (!confirm('清空 ' + name + '？')) return;
        try {
          await clearLogs(name);
        } catch (e) {
          toast(e.message);
        }
      };
    }
    if ($('#btn_log_clear_all')) {
      $('#btn_log_clear_all').onclick = async () => {
        if (!confirm('清空全部引擎日志？')) return;
        try {
          await clearLogs('');
        } catch (e) {
          toast(e.message);
        }
      };
    }
    if ($('#btn_ops_purge')) {
      $('#btn_ops_purge').onclick = async () => {
        try {
          await post('/api/v1/admin/ops/cache-purge', {
            userId: ($('#ops_purge_user') && $('#ops_purge_user').value.trim()) || '',
          });
          $('#ops_tool_msg').textContent = '缓存清理已请求';
          toast('已请求清缓存');
        } catch (e) {
          toast(e.message);
        }
      };
    }
    if ($('#btn_ops_probe')) {
      $('#btn_ops_probe').onclick = async () => {
        try {
          const url = ($('#ops_probe_url') && $('#ops_probe_url').value.trim()) || '';
          const res = await post('/api/v1/admin/ops/probe-repo', { url });
          $('#ops_tool_msg').textContent =
            (res.ok ? '可达' : '失败') +
            ' status=' +
            (res.status ?? '—') +
            (res.error ? ' ' + res.error : '');
        } catch (e) {
          toast(e.message);
        }
      };
    }

    $('#btn_settings_save').onclick = async () => {
      try {
        await post('/api/v1/admin/console-settings', {
          updateUrl: $('#set_update_url').value.trim(),
          defaultGroupId: $('#set_default_group').value,
          logo: $('#brand_logo').value.trim(),
          wallpaper: $('#brand_wallpaper').value.trim(),
          banner: $('#brand_banner').value.trim(),
          aboutUrl: $('#brand_about').value.trim(),
          supportUrl: $('#brand_support').value.trim(),
          footer: $('#brand_footer').value.trim(),
          welcome: $('#brand_welcome').value.trim(),
        });
        toast('全局设置已提交');
        await refreshSettings();
      } catch (e) {
        toast(e.message);
      }
    };

    window.addEventListener('kotv-login-required', enter);
    bindDateTimePickers();
  }

  bind();
  enter();
})();
