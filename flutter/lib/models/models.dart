class VodItem {
  VodItem({
    required this.id,
    required this.name,
    this.pic = '',
    this.remarks = '',
    this.typeName = '',
    this.site = '',
    this.action = '',
    this.vodTag = '',
    this.cate = '',
    this.folder = false,
    this.flag = '',
    this.configSource = '',
    this.positionMs = 0,
    this.durationMs = 0,
    this.styleType = '',
    this.styleRatio = 0.75,
  });

  final String id;
  final String name;
  final String pic;
  final String remarks;
  final String typeName;
  final String site;
  final String action;
  final String vodTag;
  final String cate;
  final bool folder;

  /// 历史恢复用线路 flag（vodFlag）。
  final String flag;

  /// 点播配置 source，收藏去重用；空表示旧条目。
  final String configSource;

  /// 续播进度（毫秒）。
  final int positionMs;
  final int durationMs;
  final String styleType;
  final double styleRatio;

  bool get hasAction => action.trim().isNotEmpty;

  /// `folder` 标签或 cate 非空即目录。
  bool get isFolder {
    final tag = vodTag.trim().toLowerCase();
    return folder || tag == 'folder' || cate.trim().isNotEmpty;
  }

  factory VodItem.fromJson(Map<String, dynamic> j) => VodItem(
        id: '${j['vod_id'] ?? ''}',
        name: '${j['vod_name'] ?? ''}',
        pic: '${j['vod_pic'] ?? ''}',
        remarks: '${j['vod_remarks'] ?? ''}',
        typeName: '${j['type_name'] ?? ''}',
        site: '${j['site'] ?? ''}',
        action: '${j['action'] ?? ''}',
        vodTag: '${j['vod_tag'] ?? ''}',
        cate: '${j['cate'] ?? ''}',
        folder: j['is_folder'] == true,
        flag: '${j['vod_flag'] ?? j['flag'] ?? ''}',
        configSource: '${j['config_source'] ?? ''}',
        positionMs: _asInt(j['position'] ?? j['positionMs']),
        durationMs: _asInt(j['duration'] ?? j['durationMs']),
        styleType: _styleType(j['style']),
        styleRatio: _styleRatio(j['style']),
      );

  static String _styleType(dynamic v) {
    if (v is String) return v.trim();
    if (v is Map) return '${v['type'] ?? ''}'.trim();
    return '';
  }

  static double _styleRatio(dynamic v) {
    if (v is! Map) return 0.75;
    final raw = v['ratio'];
    final n = raw is num ? raw.toDouble() : double.tryParse('$raw');
    if (n == null || n <= 0) return 0.75;
    if (n > 4) return 4;
    return n;
  }

  static int _asInt(dynamic v) {
    if (v is num) return v.toInt();
    return int.tryParse('$v') ?? 0;
  }
}

class FilterOption {
  FilterOption({required this.name, required this.value});
  final String name;
  final String value;
  factory FilterOption.fromJson(Map<String, dynamic> j) => FilterOption(
        name: '${j['n'] ?? ''}',
        value: '${j['v'] ?? ''}',
      );
}

class CategoryFilter {
  CategoryFilter(
      {required this.key,
      required this.name,
      this.init = '',
      this.values = const []});
  final String key;
  final String name;
  final String init;
  final List<FilterOption> values;
  factory CategoryFilter.fromJson(Map<String, dynamic> j) => CategoryFilter(
        key: '${j['key'] ?? ''}',
        name: '${j['name'] ?? ''}',
        init: '${j['init'] ?? ''}',
        values: ((j['value'] as List?) ?? [])
            .whereType<Map>()
            .map((e) => FilterOption.fromJson(Map<String, dynamic>.from(e)))
            .toList(),
      );
}

class CategoryType {
  CategoryType(
      {required this.id,
      required this.name,
      this.typeFlag = '',
      this.filters = const []});
  final String id;
  final String name;
  final String typeFlag;
  final List<CategoryFilter> filters;

  /// `type_flag=1` 的分类用列表，并可嵌套进目录。
  bool get isFolder => typeFlag.trim() == '1';

  factory CategoryType.fromJson(Map<String, dynamic> j) => CategoryType(
        id: '${j['type_id'] ?? ''}',
        name: '${j['type_name'] ?? ''}',
        typeFlag: '${j['type_flag'] ?? ''}',
        filters: ((j['filters'] as List?) ?? [])
            .whereType<Map>()
            .map((e) => CategoryFilter.fromJson(Map<String, dynamic>.from(e)))
            .toList(),
      );
}

class EpisodeItem {
  EpisodeItem({required this.name, required this.url, this.headers});
  final String name;

  /// 非空：引擎认为非爬虫/磁力等须解析形态；空串：须 /api/v1/play。
  /// 本机路径是否直喂由详情 `_episodeCanDirectPlay` 再判（远端须 play 换 /file/）。
  final String url;
  final Map<String, String>? headers;

  factory EpisodeItem.fromJson(Map<String, dynamic> j) {
    Map<String, String>? hdr;
    final raw = j['headers'];
    if (raw is Map) {
      final m = <String, String>{
        for (final e in raw.entries)
          if ('${e.key}'.trim().isNotEmpty && '${e.value}'.trim().isNotEmpty)
            '${e.key}': '${e.value}',
      };
      if (m.isNotEmpty) hdr = m;
    }
    return EpisodeItem(
      name: '${j['name'] ?? ''}',
      url: '${j['url'] ?? ''}'.trim(),
      headers: hdr,
    );
  }
}

class FlagLine {
  FlagLine({required this.flag, required this.show, required this.episodes});
  final String flag;
  final String show;
  final List<EpisodeItem> episodes;

  factory FlagLine.fromJson(Map<String, dynamic> j) => FlagLine(
        flag: '${j['flag'] ?? ''}',
        show: '${j['show'] ?? j['flag'] ?? ''}',
        episodes: ((j['episodes'] as List?) ?? [])
            .whereType<Map>()
            .map((e) => EpisodeItem.fromJson(Map<String, dynamic>.from(e)))
            .toList(),
      );
}

class VodDetail {
  VodDetail({
    required this.id,
    required this.name,
    this.pic = '',
    this.content = '',
    this.site = '',
    this.remarks = '',
    this.year = '',
    this.area = '',
    this.actor = '',
    this.director = '',
    this.typeName = '',
    this.flags = const [],
  });

  final String id;
  final String name;
  final String pic;
  final String content;
  final String site;
  final String remarks;
  final String year;
  final String area;
  final String actor;
  final String director;
  final String typeName;
  final List<FlagLine> flags;

  factory VodDetail.fromJson(Map<String, dynamic> j) => VodDetail(
        id: '${j['vod_id'] ?? ''}',
        name: '${j['vod_name'] ?? ''}',
        pic: '${j['vod_pic'] ?? ''}',
        content: '${j['vod_content'] ?? ''}',
        site: '${j['site'] ?? ''}',
        remarks: '${j['vod_remarks'] ?? ''}',
        year: '${j['vod_year'] ?? ''}',
        area: '${j['vod_area'] ?? ''}',
        actor: '${j['vod_actor'] ?? ''}',
        director: '${j['vod_director'] ?? ''}',
        typeName: '${j['type_name'] ?? ''}',
        flags: ((j['flags'] as List?) ?? [])
            .whereType<Map>()
            .map((e) => FlagLine.fromJson(Map<String, dynamic>.from(e)))
            .toList(),
      );

  VodDetail withFlags(List<FlagLine> next) => VodDetail(
        id: id,
        name: name,
        pic: pic,
        content: content,
        site: site,
        remarks: remarks,
        year: year,
        area: area,
        actor: actor,
        director: director,
        typeName: typeName,
        flags: next,
      );

  VodDetail withMeta({String? name, String? pic, String? content}) => VodDetail(
        id: id,
        name:
            (name != null && name.trim().isNotEmpty) ? name.trim() : this.name,
        pic: (pic != null && pic.trim().isNotEmpty) ? pic.trim() : this.pic,
        content: (content != null && content.trim().isNotEmpty)
            ? content.trim()
            : this.content,
        site: site,
        remarks: remarks,
        year: year,
        area: area,
        actor: actor,
        director: director,
        typeName: typeName,
        flags: flags,
      );
}

class SiteInfo {
  SiteInfo({
    required this.key,
    required this.name,
    this.home = false,
    this.searchable = true,
    this.changeable = true,
    this.indexs = false,
    this.type = 0,
    this.styleType = '',
  });
  final String key;
  final String name;
  final bool home;
  final bool searchable;
  final bool changeable;

  /// 豆瓣等索引站，点条目去全网搜索而不是本站详情。
  final bool indexs;

  /// 配置 type；4 为推送站（无 home/search/category，有 detail/play）。
  final int type;
  final String styleType;

  /// 推送站：详情/播放入口，无浏览首页。
  bool get isPushSite => type == 4;

  /// 空首页且可搜、非推送：提示使用顶部搜索（勿自动跳转）。
  bool showsSearchOnlyHomeHint(bool emptyHome) =>
      emptyHome && searchable && !isPushSite;

  factory SiteInfo.fromJson(Map<String, dynamic> j) => SiteInfo(
        key: '${j['key'] ?? ''}',
        name: '${j['name'] ?? ''}',
        home: j['home'] == true,
        // 与引擎 IsSearchable/IsChangeable 一致：未声明默认开；仅 true/1 为开。
        searchable: _siteFlagOn(j['searchable']),
        changeable: _siteFlagOn(j['changeable']),
        indexs: j['indexs'] == true || j['indexs'] == 1,
        type: j['type'] is num ? (j['type'] as num).toInt() : int.tryParse('${j['type'] ?? ''}') ?? 0,
        styleType: VodItem._styleType(j['style']),
      );

  /// 站源开关：null → 默认开；bool / 1 / "1" / "true" → 开；0/2/false → 关。
  static bool _siteFlagOn(dynamic v) {
    if (v == null) return true;
    if (v is bool) return v;
    if (v is num) return v.toInt() == 1;
    final s = '$v'.trim().toLowerCase();
    if (s.isEmpty) return true;
    if (s == '1' || s == 'true') return true;
    if (s == '0' || s == '2' || s == 'false') return false;
    return true;
  }

  /// 配置接口里的 `sites` 列表（已排除隐藏与用户禁用的站）。
  static List<SiteInfo> listFromConfig(Map<String, dynamic> cfg) =>
      ((cfg['sites'] as List?) ?? const [])
          .whereType<Map>()
          .map((e) => SiteInfo.fromJson(Map<String, dynamic>.from(e)))
          .toList();
}
