class VodItem {
  VodItem({
    required this.id,
    required this.name,
    this.pic = '',
    this.remarks = '',
    this.typeName = '',
    this.site = '',
  });

  final String id;
  final String name;
  final String pic;
  final String remarks;
  final String typeName;
  final String site;

  factory VodItem.fromJson(Map<String, dynamic> j) => VodItem(
        id: '${j['vod_id'] ?? ''}',
        name: '${j['vod_name'] ?? ''}',
        pic: '${j['vod_pic'] ?? ''}',
        remarks: '${j['vod_remarks'] ?? ''}',
        typeName: '${j['type_name'] ?? ''}',
        site: '${j['site'] ?? ''}',
      );
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
  CategoryFilter({required this.key, required this.name, this.init = '', this.values = const []});
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
  CategoryType({required this.id, required this.name, this.filters = const []});
  final String id;
  final String name;
  final List<CategoryFilter> filters;

  factory CategoryType.fromJson(Map<String, dynamic> j) => CategoryType(
        id: '${j['type_id'] ?? ''}',
        name: '${j['type_name'] ?? ''}',
        filters: ((j['filters'] as List?) ?? [])
            .whereType<Map>()
            .map((e) => CategoryFilter.fromJson(Map<String, dynamic>.from(e)))
            .toList(),
      );
}

class EpisodeItem {
  EpisodeItem({required this.name, required this.url});
  final String name;
  final String url;

  factory EpisodeItem.fromJson(Map<String, dynamic> j) => EpisodeItem(
        name: '${j['name'] ?? ''}',
        url: '${j['url'] ?? ''}',
      );
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
}

class SiteInfo {
  SiteInfo({
    required this.key,
    required this.name,
    this.home = false,
    this.searchable = true,
    this.changeable = true,
  });
  final String key;
  final String name;
  final bool home;
  final bool searchable;
  final bool changeable;

  factory SiteInfo.fromJson(Map<String, dynamic> j) => SiteInfo(
        key: '${j['key'] ?? ''}',
        name: '${j['name'] ?? ''}',
        home: j['home'] == true,
        searchable: j['searchable'] != false,
        changeable: j['changeable'] != false,
      );
}
