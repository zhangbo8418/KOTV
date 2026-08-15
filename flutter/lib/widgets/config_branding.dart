import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

/// 配置根 `logo`：圆形图；失败回落默认图标。点击行为由调用方决定（TV：打开历史）。
class ConfigLogoAvatar extends StatelessWidget {
  const ConfigLogoAvatar({
    super.key,
    required this.logoUrl,
    this.radius = 28,
    this.onTap,
    this.fallbackIcon = Icons.home_outlined,
    this.backgroundColor,
  });

  final String logoUrl;
  final double radius;
  final VoidCallback? onTap;
  final IconData fallbackIcon;
  final Color? backgroundColor;

  @override
  Widget build(BuildContext context) {
    final url = logoUrl.trim();
    final bg = backgroundColor ?? const Color(0xFF6E29CD);
    final child = CircleAvatar(
      radius: radius,
      backgroundColor: bg,
      backgroundImage: url.isNotEmpty && _isHttp(url) ? NetworkImage(url) : null,
      onBackgroundImageError: url.isNotEmpty && _isHttp(url) ? (_, __) {} : null,
      child: url.isNotEmpty && _isHttp(url)
          ? null
          : Icon(fallbackIcon, size: radius * 1.05, color: Colors.white),
    );
    if (onTap == null) return child;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: child,
      ),
    );
  }
}

bool _isHttp(String s) {
  final u = s.toLowerCase();
  return u.startsWith('http://') || u.startsWith('https://');
}

class ConfigBannerSlide {
  const ConfigBannerSlide({required this.image, this.title = '', this.id = ''});
  final String image;
  final String title;
  final String id;
}

/// 拉取并解析配置 `banner` URL（腾讯 map / 数组 / 单图）。
Future<List<ConfigBannerSlide>> fetchConfigBanners(String bannerUrl) async {
  final raw = bannerUrl.trim();
  if (!_isHttp(raw)) return const [];
  try {
    final resp = await http.get(Uri.parse(raw)).timeout(const Duration(seconds: 12));
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      return [ConfigBannerSlide(image: raw)];
    }
    final ct = (resp.headers['content-type'] ?? '').toLowerCase();
    final body = utf8.decode(resp.bodyBytes, allowMalformed: true).trim();
    if (ct.contains('json') || body.startsWith('[') || body.startsWith('{')) {
      final parsed = parseConfigBannerJson(body);
      if (parsed.isNotEmpty) return parsed;
    }
    return [ConfigBannerSlide(image: raw)];
  } catch (_) {
    return [ConfigBannerSlide(image: raw)];
  }
}

/// 配置根 `banner`：拉取接口 JSON 轮播。
/// 支持腾讯轮播格式：`{ "id": { "id","title","image",... }, ... }`。
class ConfigBannerPanel extends StatefulWidget {
  const ConfigBannerPanel({
    super.key,
    required this.bannerUrl,
    this.height = 160,
    this.borderRadius = 14,
    this.onTap,
  });

  final String bannerUrl;
  final double height;
  final double borderRadius;
  final void Function(ConfigBannerSlide slide)? onTap;

  @override
  State<ConfigBannerPanel> createState() => _ConfigBannerPanelState();
}

class _ConfigBannerPanelState extends State<ConfigBannerPanel> {
  List<ConfigBannerSlide> _slides = const [];
  int _idx = 0;
  Timer? _timer;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    unawaited(_resolve());
  }

  @override
  void didUpdateWidget(covariant ConfigBannerPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.bannerUrl != widget.bannerUrl) {
      unawaited(_resolve());
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  ConfigBannerSlide? get _current {
    if (_slides.isEmpty) return null;
    return _slides[_idx.clamp(0, _slides.length - 1)];
  }

  Future<void> _resolve() async {
    _timer?.cancel();
    final raw = widget.bannerUrl.trim();
    if (!_isHttp(raw)) {
      if (mounted) {
        setState(() {
          _slides = const [];
          _loading = false;
        });
      }
      return;
    }
    if (mounted) setState(() => _loading = true);
    final slides = await fetchConfigBanners(raw);
    if (!mounted) return;
    setState(() {
      _slides = slides;
      _idx = 0;
      _loading = false;
    });
    if (_slides.length > 1) {
      _timer = Timer.periodic(const Duration(seconds: 6), (_) {
        if (!mounted || _slides.isEmpty) return;
        setState(() => _idx = (_idx + 1) % _slides.length);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final cur = _current;
    final pic = cur?.image ?? '';
    final title = cur?.title.trim() ?? '';
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: cur == null ? null : () => widget.onTap?.call(cur),
        borderRadius: BorderRadius.circular(widget.borderRadius),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(widget.borderRadius),
          child: SizedBox(
            height: widget.height,
            width: double.infinity,
            child: Stack(
              fit: StackFit.expand,
              children: [
                const ColoredBox(color: Color(0xFF652291)),
                if (_loading)
                  const Center(
                    child: SizedBox(
                      width: 28,
                      height: 28,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white70),
                    ),
                  )
                else if (pic.isNotEmpty)
                  Image.network(
                    pic,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => const Center(
                      child: Icon(Icons.broken_image_outlined, color: Colors.white54, size: 36),
                    ),
                  ),
                if (!_loading && title.isNotEmpty) ...[
                  const DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [Color(0x00000000), Color(0x99000000)],
                      ),
                    ),
                  ),
                  Positioned(
                    left: 14,
                    right: 64,
                    bottom: 14,
                    child: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w700, height: 1.15),
                    ),
                  ),
                ],
                if (_slides.length > 1)
                  Positioned(
                    right: 12,
                    bottom: 12,
                    child: Text(
                      '${_idx + 1}/${_slides.length}',
                      style: const TextStyle(color: Colors.white70, fontSize: 12, fontWeight: FontWeight.w600),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 解析 banner JSON：腾讯 map、数组、或单对象。
List<ConfigBannerSlide> parseConfigBannerJson(String body) {
  try {
    final v = jsonDecode(body);
    final out = <ConfigBannerSlide>[];

    ConfigBannerSlide? fromMap(Map m) {
      String img = '';
      for (final k in ['image', 'pic', 'img', 'url', 'banner', 'cover']) {
        final s = '${m[k] ?? ''}'.trim();
        if (_isHttp(s)) {
          img = s;
          break;
        }
      }
      if (img.isEmpty) return null;
      return ConfigBannerSlide(
        image: img,
        title: '${m['title'] ?? m['name'] ?? ''}'.trim(),
        id: '${m['id'] ?? m['vod_id'] ?? ''}'.trim(),
      );
    }

    void add(dynamic x) {
      if (x is String && _isHttp(x.trim())) {
        out.add(ConfigBannerSlide(image: x.trim()));
        return;
      }
      if (x is Map) {
        final s = fromMap(x);
        if (s != null) out.add(s);
      }
    }

    if (v is List) {
      for (final e in v) {
        add(e);
      }
      return out;
    }
    if (v is Map) {
      final nested = v['list'] ?? v['data'] ?? v['banners'] ?? v['images'];
      if (nested is List) {
        for (final e in nested) {
          add(e);
        }
        if (out.isNotEmpty) return out;
      }
      // { "mzc...": { id, title, image }, ... }
      var fromValues = false;
      for (final e in v.values) {
        if (e is Map) {
          final s = fromMap(Map<dynamic, dynamic>.from(e));
          if (s != null) {
            out.add(s);
            fromValues = true;
          }
        }
      }
      if (fromValues) return out;
      add(v);
    }
    return out;
  } catch (_) {
    return const [];
  }
}
