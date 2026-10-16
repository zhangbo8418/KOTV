import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/kotv_settings_cache.dart';
import '../models/models.dart';
import '../providers.dart';
import '../remote/local_collect.dart';
import '../remote/remote_bridge.dart';
import '../theme/layout_scale.dart';
import '../theme/kotv_palette.dart';
import '../theme/kotv_theme.dart';
import '../widgets/chrome.dart';
import '../widgets/config_branding.dart';
import '../widgets/dialogs.dart';
import '../widgets/h_scroll.dart';
import '../widgets/kotv_network_image.dart';
import '../widgets/poster_card.dart';
import '../vod/grid_style.dart';
import '../vod/list_style.dart';
import '../vod/vod_open.dart';
import 'detail_screen.dart';
import 'live_screen.dart';
import 'shell.dart';

class VideoScreen extends ConsumerStatefulWidget {
  const VideoScreen({super.key});

  @override
  ConsumerState<VideoScreen> createState() => _VideoScreenState();
}

class _VideoScreenState extends ConsumerState<VideoScreen> {
  String? _tid;
  int _page = 1;
  int _pageCount = 0;
  bool _hasMore = true;
  bool _loadingMore = false;
  final _items = <VodItem>[];
  bool _listStyle = false;
  KotvGridStyle _gridStyle = const KotvGridStyle();
  List<CategoryType> _types = [];
  List<CategoryFilter> _filters = [];

  /// 筛选行默认收起；再点当前分类标题才展开。
  bool _filtersExpanded = false;
  final Map<String, String> _extend = {};
  String? _statusMsg;
  bool _loading = true;
  bool _ready = false;
  List<ConfigBannerSlide> _apiBanners = [];
  String _apiBannerUrl = '';
  int _apiBannerLoadGen = 0;

  List<VodItem> _history = [];
  List<VodItem> _keeps = [];
  final ScrollController _scroll = ScrollController();
  int _loadGen = 0;

  /// 首屏 autofill 连续续页计数（触底用户滚动不计入）。
  int _autofillStreak = 0;

  /// 合并并发 _reload，避免 bootstrap / epoch / 重试叠两次拉仓。
  Future<void>? _reloadFlight;
  RemoteBridge? _boundRemote;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _bootstrap();
      _attachRemoteHandlers();
    });
  }

  @override
  void dispose() {
    _detachRemoteHandlers();
    _scroll.dispose();
    super.dispose();
  }

  void _attachRemoteHandlers() {
    final bridge = ref.read(remoteBridgeProvider);
    if (bridge == null) return;
    _boundRemote = bridge;
    bridge.onCategoryRefresh = _onRemoteCategoryRefresh;
  }

  void _detachRemoteHandlers() {
    final bridge = _boundRemote;
    _boundRemote = null;
    if (bridge == null) return;
    if (identical(bridge.onCategoryRefresh, _onRemoteCategoryRefresh)) {
      bridge.onCategoryRefresh = null;
    }
  }

  void _onRemoteCategoryRefresh() {
    if (!mounted) return;
    unawaited(_reload(refreshRepo: true));
  }

  List<VodItem> get _bannerSlides {
    final withPic = _items.where((e) => e.pic.isNotEmpty).take(15).toList();
    if (withPic.isNotEmpty) return withPic;
    return _items.take(15).toList();
  }

  void _syncApiBanner(String url) {
    final next = url.trim();
    if (next == _apiBannerUrl) return;
    _apiBannerUrl = next;
    final gen = ++_apiBannerLoadGen;
    if (next.isEmpty) {
      if (_apiBanners.isNotEmpty && mounted) {
        setState(() => _apiBanners = []);
      }
      return;
    }
    unawaited(_loadApiBanner(next, gen));
  }

  Future<void> _loadApiBanner(String url, int gen) async {
    final slides = await fetchConfigBanners(url);
    if (!mounted || gen != _apiBannerLoadGen) return;
    setState(() => _apiBanners = slides);
  }

  void _onApiBannerTap(ConfigBannerSlide slide) {
    final q = slide.title.trim();
    if (q.isNotEmpty) {
      ref.read(pendingSearchProvider.notifier).state = q;
      goKotvPage(ref, KotvPage.search);
      return;
    }
    goKotvPage(ref, KotvPage.history);
  }

  Future<void> _refreshLocalMeta() async {
    final h = await LocalHistory.list();
    final k = await LocalCollect.list();
    if (!mounted) return;
    setState(() {
      _history = h;
      _keeps = k;
    });
  }

  Future<void> _bootstrap() async {
    await _refreshLocalMeta();
    // 暖启动：配置已 ready 且爬虫就绪时跳过 refreshRepo，直接拉首页。
    // 远端断开时由 _reload 内 recoverOrFallbackLocal 切本机并强制拉仓。
    var refreshRepo = true;
    try {
      final cfg = await ref.read(apiProvider).getConfig();
      final ready = cfg['ready'] == true;
      final spiderOk = cfg['spiderOk'] != false;
      final source = '${cfg['source'] ?? ''}'.trim();
      if (ready && spiderOk && source.isNotEmpty) {
        refreshRepo = false;
      }
    } catch (_) {}
    if (!mounted) return;
    await _reload(refreshRepo: refreshRepo, clearContent: refreshRepo);
  }

  /// 无点播源：source 空且错误像「未配置」。
  bool _isNoSourceConfig(Map<String, dynamic> cfg) {
    final source = '${cfg['source'] ?? ''}'.trim();
    if (source.isNotEmpty) return false;
    final err = '${cfg['error'] ?? ''}';
    return err.isEmpty ||
        err.contains('未配置') ||
        err.contains('点播源') ||
        err.contains('请输入');
  }

  /// 等到 ready，或确认无源；有源加载中则继续等。
  /// RK3399 等弱机：jar Init + DexNative 常要 30~90s，40s 窗口会误报超时。
  Future<Map<String, dynamic>> _waitConfigReady({int maxAttempts = 480}) async {
    final api = ref.read(apiProvider);
    Map<String, dynamic> cfg = const {};
    for (var i = 0; i < maxAttempts; i++) {
      cfg = await api.getConfig();
      if (cfg['ready'] == true) return cfg;
      if (_isNoSourceConfig(cfg)) return cfg;
      final err = '${cfg['error'] ?? ''}'.trim();
      if (err.isNotEmpty) return cfg;
      if (i == 0 && mounted) {
        setState(() {
          _ready = false;
          _loading = true;
          _statusMsg = '正在加载点播源…';
        });
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    return cfg;
  }

  Future<void> _reload({
    bool clearContent = false,
    bool refreshRepo = false,
    bool refreshConfig = false,
  }) {
    final prev = _reloadFlight;
    final run = () async {
      if (prev != null) {
        try {
          await prev;
        } catch (_) {}
      }
      await _reloadBody(
        clearContent: clearContent,
        refreshRepo: refreshRepo,
        refreshConfig: refreshConfig,
      );
    }();
    _reloadFlight = run;
    return run;
  }

  Future<void> _reloadBody({
    bool clearContent = false,
    bool refreshRepo = false,
    bool refreshConfig = false,
  }) async {
    final gen = ++_loadGen;
    var fellBack = false;
    setState(() {
      _loading = true;
      _statusMsg = null;
      _page = 1;
      _pageCount = 0;
      _hasMore = true;
      // 断线重试保留骨架；换仓/换站必须清空，避免旧海报残留
      if (clearContent) {
        _items.clear();
        _types = [];
        _filters = [];
        _filtersExpanded = false;
      }
    });
    try {
      final launcher = ref.read(engineLauncherProvider);
      final up = await launcher.recoverOrFallbackLocal();
      if (!mounted || gen != _loadGen) return;
      if (launcher.takeFellBackToLocal()) {
        fellBack = true;
        KotvSettingsCache.clear();
        ref.invalidate(engineReadyProvider);
        ref.invalidate(configProvider);
        ref.invalidate(settingsProvider);
        refreshRepo = true;
        clearContent = true;
        setState(() {
          _items.clear();
          _types = [];
          _filters = [];
          _statusMsg = '远端不可达，已切回本机引擎';
        });
      }
      if (!up) {
        setState(() {
          _ready = false;
          _statusMsg = '无法连接引擎，请稍后点重试';
          _loading = false;
        });
        return;
      }

      final cfg = await _waitConfigReady();
      if (!mounted || gen != _loadGen) return;
      final ready = cfg['ready'] == true;
      setState(() => _ready = ready);

      if (!ready) {
        final source = '${cfg['source'] ?? ''}'.trim();
        final err = '${cfg['error'] ?? ''}'.trim();
        setState(() {
          _types = [];
          _filters = [];
          _items.clear();
          _loading = false;
          // 有源却未 ready：显示错误/重试，不要伪装成「未配置」
          _statusMsg =
              source.isEmpty ? null : (err.isNotEmpty ? err : '点播源加载超时，请重试');
        });
        return;
      }

      var repoErr = '';
      if (refreshRepo) {
        final source = '${cfg['source'] ?? ''}'.trim();
        final lower = source.toLowerCase();
        if (lower.startsWith('http://') || lower.startsWith('https://')) {
          try {
            await ref
                .read(apiProvider)
                .refreshConfig()
                .timeout(const Duration(seconds: 45));
          } catch (e) {
            repoErr = '$e';
          }
        }
      }
      if (!mounted || gen != _loadGen) return;

      final data = await _fetchFirstPage(gen);
      if (!mounted || gen != _loadGen) return;
      _applyPage(data, replace: true);
      if (!mounted || gen != _loadGen) return;
      if (repoErr.isNotEmpty) {
        setState(() => _statusMsg = '仓库加载失败: $repoErr');
      } else if (fellBack) {
        setState(() => _statusMsg = '远端不可达，已切回本机引擎');
      }
      unawaited(_fillHomeRecommendIfEmpty(gen));
      _scheduleAutofill();
      // 仅配置可能变化时刷缓存；分类/筛选勿 invalidate。
      if (refreshRepo || clearContent || refreshConfig) {
        ref.invalidate(configProvider);
      }
    } catch (e) {
      if (!mounted || gen != _loadGen) return;
      final msg = '$e';
      if (msg.contains('TimeoutException') || msg.contains('Timeout')) {
        setState(() => _statusMsg = '首页加载超时，请重试或换源');
        return;
      }
      if (msg.contains('Connection refused') ||
          msg.contains('SocketException')) {
        final launcher = ref.read(engineLauncherProvider);
        final ok = await launcher.recoverOrFallbackLocal();
        if (!mounted || gen != _loadGen) return;
        final retryFellBack = launcher.takeFellBackToLocal();
        if (ok) {
          if (retryFellBack) {
            KotvSettingsCache.clear();
            ref.invalidate(engineReadyProvider);
            ref.invalidate(configProvider);
            ref.invalidate(settingsProvider);
          }
          try {
            // 重启/切本机后须再等 ready，否则会打到空仓。
            final cfg = await _waitConfigReady();
            if (!mounted || gen != _loadGen) return;
            if (cfg['ready'] != true) {
              setState(() {
                _ready = false;
                _statusMsg = '引擎已恢复，但点播源未就绪，请重试';
              });
              return;
            }
            setState(() => _ready = true);
            if (retryFellBack) {
              final source = '${cfg['source'] ?? ''}'.trim();
              final lower = source.toLowerCase();
              if (lower.startsWith('http://') || lower.startsWith('https://')) {
                try {
                  await ref
                      .read(apiProvider)
                      .refreshConfig()
                      .timeout(const Duration(seconds: 45));
                } catch (_) {}
              }
              if (!mounted || gen != _loadGen) return;
            }
            final data = await _fetchFirstPage(gen);
            if (!mounted || gen != _loadGen) return;
            _applyPage(data, replace: true);
            unawaited(_fillHomeRecommendIfEmpty(gen));
            _scheduleAutofill();
            setState(() {
              _statusMsg = retryFellBack ? '远端不可达，已切回本机引擎' : null;
            });
            if (retryFellBack) {
              ref.invalidate(configProvider);
            }
            return;
          } catch (e2) {
            if (!mounted || gen != _loadGen) return;
            setState(() => _statusMsg = '$e2');
            return;
          }
        }
      }
      setState(() => _statusMsg = msg);
    } finally {
      if (mounted && gen == _loadGen) setState(() => _loading = false);
    }
  }

  /// 首屏：分类页单次 25s；首页在超时 / 换源作废时接着请求（换仓后 jar 冷启动可达 30~90s，
  /// 引擎 singleflight 会把这次加载跑完并缓存），总共约 100s。
  Future<Map<String, dynamic>> _fetchFirstPage(int gen) async {
    final api = ref.read(apiProvider);
    final tid = _tid;
    if (tid != null && tid.isNotEmpty) {
      return api
          .category(tid, pg: '1', extend: Map<String, String>.from(_extend))
          .timeout(const Duration(seconds: 25));
    }
    const attempts = 4;
    for (var i = 0;; i++) {
      try {
        return await api.home().timeout(const Duration(seconds: 25));
      } catch (e) {
        final msg = '$e';
        final retry = msg.contains('Timeout') || msg.contains('首页加载已取消');
        if (!retry || i >= attempts - 1 || !mounted || gen != _loadGen) rethrow;
        setState(() => _statusMsg = '正在加载首页…');
      }
    }
  }

  /// APP 源常见 home 只返分类、list 为空 → 首页「为你推荐」空白；用首个分类顶上。
  Future<void> _fillHomeRecommendIfEmpty(int gen) async {
    if (!mounted || gen != _loadGen) return;
    if (_tid != null && _tid!.isNotEmpty) return;
    if (_items.isNotEmpty || _types.isEmpty) return;
    final tid = _types.first.id;
    if (tid.isEmpty) return;
    try {
      final data = await ref
          .read(apiProvider)
          .category(tid, pg: '1')
          .timeout(const Duration(seconds: 25));
      if (!mounted || gen != _loadGen) return;
      if (_tid != null && _tid!.isNotEmpty) return;
      final list = ((data['list'] as List?) ?? [])
          .whereType<Map>()
          .map((e) => VodItem.fromJson(Map<String, dynamic>.from(e)))
          .toList();
      if (list.isEmpty) return;
      setState(() {
        _items
          ..clear()
          ..addAll(list);
      });
    } catch (_) {}
  }

  /// loadCategory：先切导航/清空列表，再异步加载。
  void _switchCategory(String? tid) {
    final filters = <CategoryFilter>[];
    if (tid != null && tid.isNotEmpty) {
      for (final t in _types) {
        if (t.id == tid && t.filters.isNotEmpty) {
          filters.addAll(t.filters);
          break;
        }
      }
    }
    setState(() {
      _tid = tid;
      _extend.clear();
      _filters = filters;
      _filtersExpanded = false;
      // 仅写入非空 init，不回退到首个 value。
      for (final f in _filters) {
        if (f.init.isNotEmpty) _extend[f.key] = f.init;
      }
      _items.clear();
      _page = 1;
      _pageCount = 0;
      _hasMore = true;
      _autofillStreak = 0;
      _loading = true;
      _loadingMore = false;
      _statusMsg = null;
    });
    if (_scroll.hasClients) {
      _scroll.jumpTo(0);
    }
    unawaited(_reloadContentOnly());
  }

  void _toggleFilters() {
    if (_filters.isEmpty) return;
    setState(() => _filtersExpanded = !_filtersExpanded);
  }

  /// 筛选 chip：先更新选中态并清空瀑布流，再加载。
  void _switchFilter(String key, String value) {
    if ((_extend[key] ?? '') == value) return;
    setState(() {
      _extend[key] = value;
      _items.clear();
      _page = 1;
      _pageCount = 0;
      _hasMore = true;
      _autofillStreak = 0;
      _loading = true;
      _loadingMore = false;
      _statusMsg = null;
    });
    if (_scroll.hasClients) {
      _scroll.jumpTo(0);
    }
    unawaited(_reloadContentOnly());
  }

  /// 分类/筛选：只拉内容，不等 ready、不 refresh、不 invalidate 配置。
  Future<void> _reloadContentOnly() async {
    final gen = ++_loadGen;
    try {
      final data = await _fetchFirstPage(gen);
      if (!mounted || gen != _loadGen) return;
      _applyPage(data, replace: true);
      unawaited(_fillHomeRecommendIfEmpty(gen));
      _scheduleAutofill();
    } catch (e) {
      if (!mounted || gen != _loadGen) return;
      setState(() => _statusMsg = '$e');
    } finally {
      if (mounted && gen == _loadGen) setState(() => _loading = false);
    }
  }

  Future<void> _loadMore({bool fromAutofill = false}) async {
    if (_tid == null ||
        _tid!.isEmpty ||
        _loadingMore ||
        _loading ||
        !_ready ||
        !_hasMore) return;
    if (fromAutofill && _autofillStreak >= 3) return;
    final gen = _loadGen;
    setState(() => _loadingMore = true);
    try {
      final next = _page + 1;
      final data = await ref.read(apiProvider).category(_tid!,
          pg: '$next', extend: Map<String, String>.from(_extend));
      if (!mounted || gen != _loadGen) return;
      _applyPage(data, replace: false, requestedPage: next);
      if (fromAutofill) {
        _autofillStreak++;
      } else {
        _autofillStreak = 0;
      }
      _scheduleAutofill();
    } catch (_) {
    } finally {
      if (mounted && gen == _loadGen) setState(() => _loadingMore = false);
    }
  }

  /// 首屏装不满且还有后续页时自动续载，避免 maxScrollExtent 门槛拦死。
  void _scheduleAutofill() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_tid == null || _tid!.isEmpty) return;
      if (!_hasMore || _loadingMore || _loading || !_ready) return;
      if (_autofillStreak >= 3) return;
      if (!_scroll.hasClients) return;
      if (_scroll.position.maxScrollExtent > 80) return;
      unawaited(_loadMore(fromAutofill: true));
    });
  }

  void _applyPage(Map<String, dynamic> data,
      {required bool replace, int? requestedPage}) {
    try {
      final list = ((data['list'] as List?) ?? [])
          .whereType<Map>()
          .map((e) => VodItem.fromJson(Map<String, dynamic>.from(e)))
          .toList();
      final types = ((data['class'] as List?) ?? [])
          .whereType<Map>()
          .map((e) => CategoryType.fromJson(Map<String, dynamic>.from(e)))
          .where((t) =>
              t.id.isNotEmpty &&
              t.id != 'home' &&
              t.name != '首页' &&
              t.name != '推荐')
          .toList();
      final filters = ((data['filters'] as List?) ?? [])
          .whereType<Map>()
          .map((e) => CategoryFilter.fromJson(Map<String, dynamic>.from(e)))
          .toList();
      final pcRaw = data['pagecount'];
      final pc = (pcRaw is num) ? pcRaw.toInt() : 0;
      final home = replace && (_tid == null || _tid!.isEmpty);
      final emptyHome = home && types.isEmpty && list.isEmpty;
      final pageStyle = KotvGridStyle.parse(data['style']);
      final nextList = pageStyle.isList ||
          kotvListStyle(items: list.map((e) => e.styleType));
      setState(() {
        if (replace) {
          _listStyle = nextList;
          _gridStyle = pageStyle;
        } else if (!_listStyle) {
          _listStyle = nextList;
        }
        _statusMsg = emptyHome ? '首页没有返回分类和推荐，请重试' : null;
        if (types.isNotEmpty) {
          _types = types;
        }
        if (_tid != null && _tid!.isNotEmpty) {
          if (filters.isNotEmpty) {
            _filters = filters;
          } else {
            for (final t in _types) {
              if (t.id == _tid && t.filters.isNotEmpty) {
                _filters = t.filters;
                break;
              }
            }
          }
          // 仅用 init 作缺省，禁止用首项（会把 AppDrama 等源筛空）。
          for (final f in _filters) {
            if (f.init.isNotEmpty) _extend.putIfAbsent(f.key, () => f.init);
          }
        } else {
          _filters = [];
          _extend.clear();
        }
        if (replace) {
          _page = 1;
          _pageCount = pc < 0 ? 0 : pc;
          if (!emptyHome || _items.isEmpty) {
            _items
              ..clear()
              ..addAll(list);
          }
          final inCat = _tid != null && _tid!.isNotEmpty;
          _hasMore = inCat &&
              list.isNotEmpty &&
              (_pageCount == 0 || _page < _pageCount);
        } else if (list.isEmpty) {
          // 空页视为末页，不推进页码。
          _hasMore = false;
        } else {
          if (requestedPage != null) _page = requestedPage;
          if (pc > 0) _pageCount = pc;
          _items.addAll(list);
          _hasMore = _pageCount == 0 || _page < _pageCount;
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _statusMsg = '页面数据异常: $e');
    }
  }

  void _open(VodItem it) {
    openVodItem(
      context,
      ref,
      it,
      site: it.site,
      fromFolder: _categoryIsFolder,
      extend: Map<String, String>.from(_extend),
    );
  }

  void _searchItem(VodItem it) {
    if (it.hasAction || it.isFolder) return;
    searchByName(ref, it.name);
  }

  bool get _categoryIsFolder {
    final tid = _tid;
    if (tid == null || tid.isEmpty) return false;
    for (final t in _types) {
      if (t.id == tid) return t.isFolder;
    }
    return false;
  }

  Future<void> _openSitePicker(List<SiteInfo> sites) async {
    if (sites.isEmpty) {
      await _addSource();
      return;
    }
    await showSitePicker(
      context,
      ref,
      sites: sites,
      onSelect: (key) async {
        final name = () {
          for (final s in sites) {
            if (s.key == key) return s.name;
          }
          return key;
        }();
        // 换源前先硬停详情/直播，再清栈，避免后台继续出声。
        await DetailScreen.prepareLeave();
        await LiveScreen.prepareLeave();
        final nav = Navigator.of(context);
        if (nav.canPop()) {
          nav.popUntil((r) => r.isFirst);
        }
        // 只保留全局遮罩一层转圈，避免与页内 spinner 叠两层
        ref.read(uiBusyProvider.notifier).state = '正在切换到 $name…';
        setState(() {
          _tid = null;
          _extend.clear();
          _filters = [];
          _types = [];
          _items.clear();
          _statusMsg = null;
        });
        try {
          await ref.read(apiProvider).setHome(key);
          // 配置在首页请求结束之后再刷新。_reload 返回时会 invalidate。
          await _reload(clearContent: true);
        } catch (e) {
          if (mounted) setState(() => _statusMsg = '切换失败: $e');
        } finally {
          ref.read(uiBusyProvider.notifier).state = null;
        }
      },
    );
  }

  Future<void> _addSource() async {
    final loaded = await showAddVodDialog(context, ref);
    if (!mounted) return;
    await _refreshLocalMeta();
    if (!loaded || !mounted) return;
    setState(() {
      _tid = null;
      _extend.clear();
    });
    await _reload(clearContent: true);
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<int>(vodContentEpochProvider, (prev, next) {
      if (prev == null || prev == next) return;
      // 网盘授权等只刷新列表文案；勿 clearContent，否则清空 _types 只剩「首页」。
      unawaited(_reload(refreshConfig: true));
    });
    try {
      return _buildRoot(context);
    } catch (e, st) {
      debugPrint('VideoScreen build error: $e\n$st');
      final p = KotvPalette.of(context);
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.error_outline, color: p.primary, size: 40),
              const SizedBox(height: 12),
              Text('首页渲染出错',
                  style: TextStyle(
                      color: p.fg, fontSize: 16, fontWeight: FontWeight.w600)),
              const SizedBox(height: 8),
              Text('$e',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: p.muted, fontSize: 12)),
              const SizedBox(height: 16),
              AppPill(
                  label: '重试',
                  width: 100,
                  onTap: () => _reload(clearContent: true)),
            ],
          ),
        ),
      );
    }
  }

  Widget _buildRoot(BuildContext context) {
    final cfg = ref.watch(configProvider);
    final sites = cfg.maybeWhen(
      data: (c) {
        try {
          return ((c['sites'] as List?) ?? [])
              .whereType<Map>()
              .map((e) => SiteInfo.fromJson(Map<String, dynamic>.from(e)))
              .toList();
        } catch (_) {
          return <SiteInfo>[];
        }
      },
      orElse: () => <SiteInfo>[],
    );
    SiteInfo? home;
    final homeKey = cfg.maybeWhen(
        data: (c) => '${c['home'] ?? ''}'.trim(), orElse: () => '');
    final homeNameCfg = cfg.maybeWhen(
        data: (c) => '${c['homeName'] ?? ''}'.trim(), orElse: () => '');
    for (final s in sites) {
      if (homeKey.isNotEmpty ? s.key == homeKey : s.home) {
        home = s;
        break;
      }
    }
    // 隐藏站作首页时不在 sites[]；用顶层 home/homeName。
    if (home == null && homeKey.isNotEmpty) {
      home = SiteInfo(
          key: homeKey,
          name: homeNameCfg.isNotEmpty ? homeNameCfg : homeKey,
          home: true);
    }
    home ??= sites.isEmpty ? null : sites.first;
    final cfgSource = cfg.maybeWhen(
        data: (c) => '${c['source'] ?? ''}'.trim(), orElse: () => '');
    final cfgReady =
        cfg.maybeWhen(data: (c) => c['ready'] == true, orElse: () => false);
    final ready = _ready || cfgReady;
    // 有源但尚未 ready：显示加载，而不是「请先添加点播源」
    // 勿用 contains('加载')：会误伤「点播源加载超时」，导致超时后永久转圈。
    final msg = _statusMsg ?? '';
    final hasConfiguredSource = cfgSource.isNotEmpty || sites.isNotEmpty;
    final loadingSource = !ready &&
        (_loading ||
            msg.contains('正在加载') ||
            msg.contains('超时') ||
            msg.contains('无法连接') ||
            (hasConfiguredSource && msg.isEmpty));
    final siteName = !ready
        ? (loadingSource ? '加载中…' : '未配置源')
        : ((home != null && home.name.isNotEmpty)
            ? home.name
            : cfg.maybeWhen(
                data: (c) => c['ready'] == true ? '选站' : '未配置源',
                orElse: () => '…'));
    final busy = ref.watch(uiBusyProvider);
    final onHome = (_tid ?? '').isEmpty;

    return Column(
      children: [
        TopStatusBar(
          siteName: siteName,
          onRepo: () async {
            final switched = await showRepoPicker(context, ref);
            if (!switched || !mounted) return;
            setState(() {
              _tid = null;
              _extend.clear();
              _filters = [];
              _filtersExpanded = false;
              _types = [];
              _items.clear();
              _statusMsg = null;
            });
            // 多仓切换已有全局遮罩；内容必须清空后再拉，避免旧仓海报残留
            await _reload(clearContent: true);
          },
          onSite: () => _openSitePicker(sites),
          onSettings: () => goKotvPage(ref, KotvPage.settings),
          onNews: () => showAppNews(context, remoteHint(ref)),
        ),
        // 未就绪不画分类导航
        if (ready)
          CategoryNavBar(
            homeLabel: onHome ? '换源' : '首页',
            homeSelected: onHome,
            onHome: () {
              if (onHome) {
                _openSitePicker(sites);
              } else {
                _switchCategory(null);
              }
            },
            categories: [
              for (final t in _types)
                (
                  id: t.id,
                  name: t.name,
                  hasFilters: t.filters.isNotEmpty ||
                      (t.id == _tid && _filters.isNotEmpty),
                ),
            ],
            selectedTid: _tid,
            filtersExpanded: _filtersExpanded,
            onCategory: (tid) => _switchCategory(tid),
            onToggleFilter: _toggleFilters,
            onLive: () => goKotvPage(ref, KotvPage.live),
          ),
        if (ready && !onHome && _filtersExpanded && _filters.isNotEmpty)
          _buildFilters(),
        if (ready && _statusMsg != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(28, 6, 28, 0),
            child: Row(
              children: [
                Expanded(
                  child: Text(_statusMsg ?? '',
                      style: TextStyle(
                          color: KotvPalette.of(context).muted, fontSize: 13)),
                ),
                AppPill(
                    label: '重试',
                    width: 88,
                    height: 32,
                    fontSize: 13,
                    onTap: _reload),
              ],
            ),
          ),
        Expanded(
          child: !ready
              ? (loadingSource ? _buildLoadingSource() : _buildNotReady())
              : _buildBody(),
        ),
        // 有全局遮罩时不再画底栏进度条，避免两层转圈
        if (busy == null && (_loading || _loadingMore))
          const LinearProgressIndicator(minHeight: 2, color: Color(0xFFCF4274)),
      ],
    );
  }

  Widget _buildLoadingSource() {
    final p = KotvPalette.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(
            width: 36,
            height: 36,
            child: CircularProgressIndicator(
                strokeWidth: 3, color: Color(0xFFCF4274)),
          ),
          const SizedBox(height: 16),
          Text('正在加载点播源…',
              style: TextStyle(
                  color: p.fg, fontSize: 18, fontWeight: FontWeight.w700)),
          if ((_statusMsg ?? '').isNotEmpty &&
              !(_statusMsg ?? '').contains('正在加载')) ...[
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Text(_statusMsg!,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: p.muted, fontSize: 13)),
            ),
            const SizedBox(height: 14),
            AppPill(
                label: '重试',
                width: 100,
                onTap: () => _reload(clearContent: true)),
          ],
        ],
      ),
    );
  }

  Widget _buildNotReady() {
    final p = KotvPalette.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('请先添加点播源',
              style: TextStyle(
                  color: p.fg, fontSize: 22, fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          Text('粘贴配置 URL 或 JSON，即可开始大屏观影', style: TextStyle(color: p.muted)),
          const SizedBox(height: 16),
          AppPill(
              label: '添加点播源', width: 160, autofocus: true, onTap: _addSource),
        ],
      ),
    );
  }

  Widget _buildFilters() {
    final compact = KotvLayout.isCompact(context);
    final p = KotvPalette.of(context);
    final padH = compact ? 10.0 : 24.0;
    // 标签仅两字宽，桌面 72 会造成与胶囊之间大片空档
    final labelW = compact ? 36.0 : 44.0;
    final pillW = compact ? null : 88.0;
    final pillH = compact ? 28.0 : 36.0;
    final pillFs = compact ? 12.0 : 13.0;
    final sepW = compact ? 4.0 : 8.0;
    return Container(
      padding: EdgeInsets.fromLTRB(padH, 4, padH, 4),
      child: Column(
        children: [
          for (final f in _filters)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Builder(builder: (context) {
                final selIdx = f.values
                    .indexWhere((v) => (_extend[f.key] ?? '') == v.value);
                return Row(
                  children: [
                    SizedBox(
                      width: labelW,
                      child: Text(
                        f.name,
                        style: TextStyle(
                          color: p.fg.withOpacity(p.light ? 0.72 : 0.78),
                          fontSize: compact ? 12 : 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    Expanded(
                      child: SizedBox(
                        height: pillH,
                        child: HScrollList(
                          scrollToIndex: selIdx >= 0 ? selIdx : null,
                          itemStride: pillW == null
                              ? null
                              : pillW * LayoutScale.layoutOf(context) + sepW,
                          itemCount: f.values.length,
                          separatorBuilder: (_, __) => SizedBox(width: sepW),
                          itemBuilder: (_, i) {
                            final v = f.values[i];
                            final sel = (_extend[f.key] ?? '') == v.value;
                            return AppPill(
                              label: v.name,
                              width: pillW,
                              height: pillH,
                              fontSize: pillFs,
                              selected: sel,
                              onTap: () => _switchFilter(f.key, v.value),
                            );
                          },
                        ),
                      ),
                    ),
                  ],
                );
              }),
            ),
        ],
      ),
    );
  }

  Widget _buildBody() {
    final busy = ref.watch(uiBusyProvider);
    // 全局遮罩已在转圈时，页内不再叠第二个 spinner
    if (busy == null && _loading && _items.isEmpty && _types.isEmpty) {
      return Center(
          child: CircularProgressIndicator(
              color: KotvPalette.of(context).primary));
    }

    final onHome = (_tid ?? '').isEmpty;
    final pad = KotvLayout.isCompact(context) ? 12.0 : 30.0;
    final catPad = KotvLayout.isCompact(context) ? 16.0 : 60.0;
    final bottomPad = 24.0;
    return NotificationListener<ScrollNotification>(
      onNotification: (n) {
        // 短列表 maxScrollExtent≈0 时勿触底连打。
        if (!onHome &&
            n.metrics.maxScrollExtent > 80 &&
            n.metrics.pixels > n.metrics.maxScrollExtent - 300) {
          _loadMore();
        }
        return false;
      },
      child: CustomScrollView(
        controller: _scroll,
        cacheExtent: 800,
        slivers: [
          if (onHome) ...[
            SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.fromLTRB(
                    pad * LayoutScale.of(context),
                    10 * LayoutScale.of(context),
                    pad * LayoutScale.of(context),
                    0),
                child: _buildHomeFeatureGrid(),
              ),
            ),
            SliverToBoxAdapter(
                child: SizedBox(height: 16 * LayoutScale.of(context))),
            SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.symmetric(
                    horizontal: pad * LayoutScale.of(context)),
                child: const SectionTitle('为你推荐', subtitle: '来自当前站源的热门内容'),
              ),
            ),
            SliverToBoxAdapter(
                child: SizedBox(height: 10 * LayoutScale.of(context))),
            if (_items.isEmpty && _loading)
              SliverFillRemaining(
                hasScrollBody: false,
                child: Center(
                    child: CircularProgressIndicator(
                        color: KotvPalette.of(context).primary)),
              )
            else
              SliverPadding(
                padding: EdgeInsets.fromLTRB(
                    pad * LayoutScale.of(context),
                    0,
                    pad * LayoutScale.of(context),
                    bottomPad * LayoutScale.of(context)),
                sliver:
                    _listStyle ? _listSliver(_items) : _posterSliver(_items),
              ),
          ] else ...[
            SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.fromLTRB(catPad, 10, catPad, 0),
                child: SectionTitle(
                  _types
                          .where((t) => t.id == _tid)
                          .map((t) => t.name)
                          .firstOrNull ??
                      '分类',
                  subtitle: '发现更多精彩内容',
                ),
              ),
            ),
            const SliverToBoxAdapter(child: SizedBox(height: 10)),
            if (_items.isEmpty && _loading)
              SliverFillRemaining(
                hasScrollBody: false,
                child: Center(
                    child: CircularProgressIndicator(
                        color: KotvPalette.of(context).primary)),
              )
            else if (_items.isEmpty)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.all(40),
                  child: Center(
                      child: Text('暂无内容',
                          style:
                              TextStyle(color: KotvPalette.of(context).muted))),
                ),
              )
            else
              SliverPadding(
                padding: EdgeInsets.fromLTRB(catPad, 0, catPad, bottomPad),
                sliver: _categoryIsFolder || _listStyle
                    ? _listSliver(_items)
                    : _posterSliver(_items),
              ),
          ],
        ],
      ),
    );
  }

  /// 四列等宽网格。
  /// 左上两卡与下方四卡完全同宽同高；轮播 = 右三列 × 两行高。
  /// 有接口 banner 时只替换轮播内容，功能卡布局不变。
  Widget _buildHomeFeatureGrid() {
    // 只盯 banner 字段，避免配置其它字段刷新重建整块首页网格。
    final bannerUrl = ref.watch(configProvider.select(
      (async) => async.maybeWhen(
        data: (c) => '${c['banner'] ?? ''}'.trim(),
        orElse: () => '',
      ),
    ));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _syncApiBanner(bannerUrl);
    });

    final useApi = _apiBanners.isNotEmpty;
    final vodSlides = _bannerSlides;
    final bannerSlides = <_HomeBannerSlide>[
      if (useApi)
        for (final s in _apiBanners)
          _HomeBannerSlide(
            title: s.title,
            subtitle: '点击搜索相关内容',
            emptyTitle: '正在加载推荐…',
            pic: s.image,
            onTap: () => _onApiBannerTap(s),
          )
      else
        for (final s in vodSlides)
          _HomeBannerSlide(
            title: s.name.isNotEmpty ? s.name : '暂无推荐内容',
            subtitle: s.remarks.isNotEmpty ? s.remarks : '点击查看详情并播放',
            emptyTitle: '暂无推荐内容',
            pic: s.pic,
            onTap: () => _open(s),
          ),
    ];
    if (bannerSlides.isEmpty) {
      bannerSlides.add(
        _HomeBannerSlide(
          title: '',
          subtitle: '配置源后这里会轮播推荐',
          emptyTitle: useApi ? '正在加载推荐…' : '暂无推荐内容',
          pic: '',
          onTap: null,
        ),
      );
    }
    final bottomNav = KotvLayout.useBottomNav(context);
    final compact = KotvLayout.isCompact(context);

    final continueSub = _history.isEmpty
        ? (compact ? '暂无记录' : '暂无观看记录')
        : _ellipsize(_history.first.name, compact ? 8 : 14);
    final keepSub = _keeps.isEmpty
        ? (compact ? '收藏夹' : '喜欢的东西都在这里')
        : (compact ? '${_keeps.length} 个收藏' : '${_keeps.length} 个收藏内容');
    final histSub = _history.isEmpty
        ? (compact ? '暂无历史' : '你看过的都在这里')
        : (compact ? '${_history.length} 条记录' : '${_history.length} 条最近记录');

    Widget feature({
      required String title,
      required String subtitle,
      required Color start,
      required Color end,
      required IconData icon,
      required VoidCallback onTap,
      required double h,
    }) {
      return FeatureCard(
        title: title,
        subtitle: subtitle,
        start: start,
        end: end,
        icon: icon,
        height: h,
        onTap: onTap,
      );
    }

    // 轮播自管定时器，换帧不整页 setState。
    Widget banner(double radius) => _HomeRotatingBanner(
          key: ValueKey(useApi
              ? 'api|$bannerUrl|${bannerSlides.length}'
              : 'vod|${bannerSlides.length}'),
          slides: bannerSlides,
          radius: radius,
        );

    // 竖屏：轮播 + 下方两列功能卡
    if (bottomNav || compact) {
      final gap = 10.0;
      final cardH = 76.0;
      final actions = <Widget>[
        feature(
          title: '继续观看',
          subtitle: continueSub,
          start: const Color(0xF2E46643),
          end: const Color(0xF2DB4F45),
          icon: Icons.replay,
          h: cardH,
          onTap: () {
            if (_history.isNotEmpty) {
              _open(_history.first);
            } else {
              goKotvPage(ref, KotvPage.history);
            }
          },
        ),
        feature(
          title: '收藏',
          subtitle: keepSub,
          start: const Color(0xF2D55999),
          end: const Color(0xF2C04DA4),
          icon: Icons.check_circle_outline,
          h: cardH,
          onTap: () => goKotvPage(ref, KotvPage.collect),
        ),
        feature(
          title: '历史记录',
          subtitle: histSub,
          start: const Color(0xF25598D8),
          end: const Color(0xF24C7EC7),
          icon: Icons.access_time,
          h: cardH,
          onTap: () => goKotvPage(ref, KotvPage.history),
        ),
        if (!bottomNav)
          feature(
            title: '直播',
            subtitle: '央视、卫视一网打尽',
            start: const Color(0xF2B44388),
            end: const Color(0xF27840A7),
            icon: Icons.videocam_outlined,
            h: cardH,
            onTap: () => goKotvPage(ref, KotvPage.live),
          ),
      ];
      return Column(
        children: [
          SizedBox(height: 150, child: banner(10)),
          SizedBox(height: gap),
          for (var i = 0; i < actions.length; i += 2) ...[
            if (i > 0) SizedBox(height: gap),
            SizedBox(
              height: cardH,
              child: Row(
                children: [
                  Expanded(child: actions[i]),
                  if (i + 1 < actions.length) ...[
                    SizedBox(width: gap),
                    Expanded(child: actions[i + 1]),
                  ],
                ],
              ),
            ),
          ],
        ],
      );
    }

    return LayoutBuilder(
      builder: (context, c) {
        final gap = 16.0;
        final w = c.maxWidth;
        // 四列等宽：左列宽 = 下方每张卡宽
        final cardW = ((w - gap * 3) / 4).clamp(48.0, 400.0);
        // 卡高略小于宽，接近参考图比例
        final cardH = (cardW * 0.52).clamp(100.0, 132.0);
        final heroH = cardH * 2 + gap;

        Widget cell(Widget child) =>
            SizedBox(width: cardW, height: cardH, child: child);

        return Column(
          children: [
            SizedBox(
              height: heroH,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(
                    width: cardW,
                    child: Column(
                      children: [
                        cell(feature(
                          title: '搜索',
                          subtitle: '搜索一下，看尽天下',
                          start: const Color(0xF26742D1),
                          end: const Color(0xF24D2BB5),
                          icon: Icons.search,
                          h: cardH,
                          onTap: () => goKotvPage(ref, KotvPage.search),
                        )),
                        SizedBox(height: gap),
                        cell(feature(
                          title: '个人中心',
                          subtitle: '管理收藏与播放记录',
                          start: const Color(0xF6E8C158),
                          end: const Color(0xF6D2A240),
                          icon: Icons.person_outline,
                          h: cardH,
                          onTap: () => goKotvPage(ref, KotvPage.profile),
                        )),
                      ],
                    ),
                  ),
                  SizedBox(width: gap),
                  Expanded(child: banner(14)),
                ],
              ),
            ),
            SizedBox(height: gap),
            SizedBox(
              height: cardH,
              child: Row(
                children: [
                  cell(feature(
                    title: '继续观看',
                    subtitle: continueSub,
                    start: const Color(0xF2E46643),
                    end: const Color(0xF2DB4F45),
                    icon: Icons.replay,
                    h: cardH,
                    onTap: () {
                      if (_history.isNotEmpty) {
                        _open(_history.first);
                      } else {
                        goKotvPage(ref, KotvPage.history);
                      }
                    },
                  )),
                  SizedBox(width: gap),
                  cell(feature(
                    title: '收藏',
                    subtitle: keepSub,
                    start: const Color(0xF2D55999),
                    end: const Color(0xF2C04DA4),
                    icon: Icons.check_circle_outline,
                    h: cardH,
                    onTap: () => goKotvPage(ref, KotvPage.collect),
                  )),
                  SizedBox(width: gap),
                  cell(feature(
                    title: '历史记录',
                    subtitle: histSub,
                    start: const Color(0xF25598D8),
                    end: const Color(0xF24C7EC7),
                    icon: Icons.access_time,
                    h: cardH,
                    onTap: () => goKotvPage(ref, KotvPage.history),
                  )),
                  SizedBox(width: gap),
                  cell(feature(
                    title: '直播',
                    subtitle: '央视、卫视一网打尽',
                    start: const Color(0xF2B44388),
                    end: const Color(0xF27840A7),
                    icon: Icons.videocam_outlined,
                    h: cardH,
                    onTap: () => goKotvPage(ref, KotvPage.live),
                  )),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _listSliver(List<VodItem> items) {
    final p = KotvPalette.of(context);
    return SliverList(
      delegate: SliverChildBuilderDelegate(
        (context, i) {
          if (i < 0 || i >= items.length) return const SizedBox.shrink();
          final it = items[i];
          if (_listStyle) {
            return VodListTile(
              item: it,
              onTap: () => _open(it),
              onLongPress: () => _searchItem(it),
            );
          }
          return TvFocus(
            onPressed: () => _open(it),
            onLongPress: () => _searchItem(it),
            child: ListTile(
              leading: Icon(
                it.isFolder ? Icons.folder_outlined : Icons.movie_outlined,
                color: p.primary,
              ),
              title:
                  Text(it.name, maxLines: 2, overflow: TextOverflow.ellipsis),
              subtitle: it.remarks.isEmpty ? null : Text(it.remarks),
              trailing: it.isFolder ? const Icon(Icons.chevron_right) : null,
              onTap: () => _open(it),
              onLongPress: () => _searchItem(it),
            ),
          );
        },
        childCount: items.length,
        addAutomaticKeepAlives: false,
      ),
    );
  }

  Widget _posterSliver(List<VodItem> items) {
    final size = kotvWatchPosterSize(ref);
    return SliverLayoutBuilder(
      builder: (context, constraints) {
        final extent = constraints.crossAxisExtent;
        final m = kotvPosterMetrics(context,
            extent: extent, style: _gridStyle, size: size);
        return SliverGrid(
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: m.columns,
            mainAxisSpacing: m.gap,
            crossAxisSpacing: m.gap,
            childAspectRatio: m.aspect,
          ),
          delegate: SliverChildBuilderDelegate(
            (context, i) {
              if (i < 0 || i >= items.length) return const SizedBox.shrink();
              final it = items[i];
              return PosterCard(
                item: it,
                autofocus: false,
                ratio: _gridStyle.ratio,
                oval: _gridStyle.isOval,
                onTap: () => _open(it),
                onLongPress: () => _searchItem(it),
              );
            },
            childCount: items.length,
            addAutomaticKeepAlives: false,
          ),
        );
      },
    );
  }

  String _ellipsize(String s, int n) =>
      s.length <= n ? s : '${s.substring(0, n)}…';
}

class _HomeBannerSlide {
  const _HomeBannerSlide({
    required this.title,
    required this.subtitle,
    required this.emptyTitle,
    required this.pic,
    required this.onTap,
  });

  final String title;
  final String subtitle;
  final String emptyTitle;
  final String pic;
  final VoidCallback? onTap;
}

/// 首页轮播：自管定时器，换帧只重建本卡。
class _HomeRotatingBanner extends StatefulWidget {
  const _HomeRotatingBanner({
    super.key,
    required this.slides,
    required this.radius,
  });

  final List<_HomeBannerSlide> slides;
  final double radius;

  @override
  State<_HomeRotatingBanner> createState() => _HomeRotatingBannerState();
}

class _HomeRotatingBannerState extends State<_HomeRotatingBanner> {
  int _idx = 0;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 6), (_) {
      if (!mounted || widget.slides.length < 2) return;
      setState(() => _idx = (_idx + 1) % widget.slides.length);
    });
  }

  @override
  void didUpdateWidget(covariant _HomeRotatingBanner oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.slides.length != oldWidget.slides.length) {
      _idx = 0;
    } else if (widget.slides.isNotEmpty) {
      _idx = _idx % widget.slides.length;
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  static bool _isHttpUrl(String s) {
    final u = kotvParseImageUrl(s).url;
    return u.startsWith('http://') || u.startsWith('https://');
  }

  @override
  Widget build(BuildContext context) {
    final n = widget.slides.length;
    final cur = n == 0 ? null : widget.slides[_idx % n];
    final title = (cur?.title ?? '').trim();
    final sub = cur?.subtitle ?? '';
    final pic = cur?.pic ?? '';
    final emptyTitle = cur?.emptyTitle ?? '暂无推荐内容';
    final onTap = cur?.onTap;

    return TvFocus(
      onPressed: onTap ?? () {},
      borderRadius: widget.radius,
      child: GestureDetector(
        onTap: onTap,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(widget.radius),
          child: Stack(
            fit: StackFit.expand,
            children: [
              const ColoredBox(color: Color(0xFF652291)),
              if (_isHttpUrl(pic))
                KotvNetworkImage(
                  pic,
                  fit: BoxFit.cover,
                  gaplessPlayback: true,
                  errorBuilder: (_, __, ___) => const SizedBox(),
                ),
              Positioned(
                left: 14,
                right: 14,
                bottom: 40,
                child: Text(
                  title.isNotEmpty ? title : emptyTitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    height: 1.15,
                    shadows: [
                      Shadow(
                          color: Color(0xCC000000),
                          blurRadius: 8,
                          offset: Offset(0, 1))
                    ],
                  ),
                ),
              ),
              Positioned(
                left: 14,
                right: 64,
                bottom: 14,
                child: Text(
                  sub,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.92),
                    fontSize: 13,
                    height: 1.15,
                    shadows: const [
                      Shadow(
                          color: Color(0x99000000),
                          blurRadius: 6,
                          offset: Offset(0, 1))
                    ],
                  ),
                ),
              ),
              if (n > 0)
                Positioned(
                  right: 14,
                  bottom: 14,
                  child: Text(
                    '${(_idx % n) + 1}/$n',
                    style: const TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

extension _FirstOrNull<E> on Iterable<E> {
  E? get firstOrNull {
    final it = iterator;
    return it.moveNext() ? it.current : null;
  }
}
