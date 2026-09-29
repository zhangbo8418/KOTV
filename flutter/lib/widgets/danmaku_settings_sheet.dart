import 'dart:async';

import 'package:flutter/material.dart';

import '../theme/kotv_palette.dart';
import 'dialogs.dart';

/// 弹幕完整设置（设置页与播放页「更多」共用）。
Future<void> showKotvDanmakuSettingsSheet({
  required BuildContext context,
  required Future<Map<String, String>> Function() loadSettings,
  required Future<void> Function(String key, String value) persist,
  VoidCallback? onChanged,
}) async {
  final initial = Map<String, String>.from(await loadSettings());
  if (!context.mounted) return;
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (ctx) {
      return _DanmakuSettingsBody(
        initial: initial,
        persist: persist,
        onChanged: onChanged,
      );
    },
  );
  onChanged?.call();
}

class _DanmakuSettingsBody extends StatefulWidget {
  const _DanmakuSettingsBody({
    required this.initial,
    required this.persist,
    this.onChanged,
  });

  final Map<String, String> initial;
  final Future<void> Function(String key, String value) persist;
  final VoidCallback? onChanged;

  @override
  State<_DanmakuSettingsBody> createState() => _DanmakuSettingsBodyState();
}

class _DanmakuSettingsBodyState extends State<_DanmakuSettingsBody> {
  late Map<String, String> _s = Map<String, String>.from(widget.initial);

  String g(String k, [String d = '']) {
    final v = _s[k];
    return (v != null && v.isNotEmpty) ? v : d;
  }

  bool flag(String key, [bool def = true]) {
    final v = g(key, def ? 'true' : 'false').toLowerCase();
    if (v == 'false' || v == '0' || v == 'off') return false;
    if (v == 'true' || v == '1' || v == 'on') return true;
    return def;
  }

  Future<void> _set(String key, String value) async {
    setState(() => _s[key] = value);
    await widget.persist(key, value);
    widget.onChanged?.call();
  }

  Future<void> _promptText(String title, String hint, String current) async {
    final c = TextEditingController(text: current);
    final pal = KotvPalette.of(context);
    final v = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: pal.dialogBg,
        title: Text(title, style: TextStyle(color: pal.fg)),
        content: TextField(
          controller: c,
          autofocus: true,
          style: TextStyle(color: pal.fg),
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: TextStyle(color: pal.muted),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text('取消', style: TextStyle(color: pal.muted))),
          TextButton(onPressed: () => Navigator.pop(ctx, c.text.trim()), child: Text('确定', style: TextStyle(color: pal.fg))),
        ],
      ),
    );
    c.dispose();
    if (v != null) await _set('danmakuApi', v);
  }

  Widget _toggle(String label, bool value, Future<void> Function(bool) onChanged) {
    final p = KotvPalette.of(context);
    return ListTile(
      title: Text(label, style: TextStyle(color: p.fg, fontSize: 15, fontWeight: FontWeight.w500)),
      trailing: Switch.adaptive(value: value, onChanged: (v) => unawaited(onChanged(v))),
    );
  }

  Widget _nav(String label, String value, VoidCallback onTap) {
    final p = KotvPalette.of(context);
    return ListTile(
      title: Text(label, style: TextStyle(color: p.fg, fontSize: 15, fontWeight: FontWeight.w500)),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(value, style: TextStyle(color: p.muted, fontSize: 13)),
          Icon(Icons.chevron_right, color: p.muted),
        ],
      ),
      onTap: onTap,
    );
  }

  Widget _slider({
    required String label,
    required double value,
    required double min,
    required double max,
    int divisions = 20,
    required String Function(double) format,
    required void Function(double) onChanging,
    required Future<void> Function(double) onCommit,
  }) {
    final p = KotvPalette.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(child: Text(label, style: TextStyle(color: p.fg, fontSize: 14, fontWeight: FontWeight.w500))),
              Text(format(value), style: TextStyle(color: p.muted, fontSize: 13)),
            ],
          ),
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 3,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
            ),
            child: Slider(
              value: value.clamp(min, max),
              min: min,
              max: max,
              divisions: divisions,
              label: format(value),
              onChanged: onChanging,
              onChangeEnd: (v) => unawaited(onCommit(v)),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = KotvPalette.of(context);
    final h = MediaQuery.sizeOf(context).height * 0.72;
    final on = g('danmaku', 'false').toLowerCase() == 'true';
    final size = (double.tryParse(g('danmakuSize', '18')) ?? 18).clamp(12.0, 48.0);
    final opacity = (double.tryParse(g('danmakuOpacity', '85')) ?? 85).clamp(0.0, 100.0);
    final rows = (double.tryParse(g('danmakuRows', '6')) ?? 6).clamp(1.0, 16.0);
    final offset = (double.tryParse(g('danmakuOffsetMs', '0')) ?? 0).clamp(-300000.0, 300000.0);
    final maxOnScreen = (double.tryParse(g('danmakuMaxOnScreen', '150')) ?? 150).clamp(10.0, 500.0);
    final scrollArea = (double.tryParse(g('danmakuScrollArea', '50')) ?? 50).clamp(10.0, 100.0);

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        child: Material(
          color: p.dialogBg,
          borderRadius: BorderRadius.circular(16),
          clipBehavior: Clip.antiAlias,
          child: SizedBox(
            height: h,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 14, 8, 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text('弹幕设置', style: TextStyle(color: p.fg, fontSize: 17, fontWeight: FontWeight.w700)),
                      ),
                      IconButton(
                        onPressed: () => Navigator.pop(context),
                        icon: Icon(Icons.close, color: p.muted),
                      ),
                    ],
                  ),
                ),
                Divider(height: 1, color: p.fg.withOpacity(0.08)),
                Expanded(
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(8, 8, 8, 24),
                    children: [
                      _toggle('开启弹幕', on, (v) => _set('danmaku', v ? 'true' : 'false')),
                      _toggle('加载弹幕', flag('danmakuLoad'), (v) => _set('danmakuLoad', v ? 'true' : 'false')),
                      _toggle('自动搜索弹幕', flag('danmakuAuto'), (v) => _set('danmakuAuto', v ? 'true' : 'false')),
                      _toggle('片源弹幕优先', flag('danmakuSpiderFirst'), (v) => _set('danmakuSpiderFirst', v ? 'true' : 'false')),
                      _nav(
                        '弹幕 API',
                        g('danmakuApi').isEmpty ? '未配置' : '已配置',
                        () => unawaited(_promptText('弹幕 API', 'https://…?n={name}&e={episode}', g('danmakuApi'))),
                      ),
                      _slider(
                        label: '字号',
                        value: size,
                        min: 12,
                        max: 48,
                        divisions: 36,
                        format: (v) => '${v.round()}',
                        onChanging: (v) => setState(() => _s['danmakuSize'] = '${v.round()}'),
                        onCommit: (v) => _set('danmakuSize', '${v.round()}'),
                      ),
                      _slider(
                        label: '透明度',
                        value: opacity,
                        min: 15,
                        max: 100,
                        divisions: 17,
                        format: (v) => '${v.round()}%',
                        onChanging: (v) => setState(() => _s['danmakuOpacity'] = '${v.round()}'),
                        onCommit: (v) => _set('danmakuOpacity', '${v.round()}'),
                      ),
                      _slider(
                        label: '行数',
                        value: rows,
                        min: 1,
                        max: 16,
                        divisions: 15,
                        format: (v) => '${v.round()}',
                        onChanging: (v) => setState(() => _s['danmakuRows'] = '${v.round()}'),
                        onCommit: (v) => _set('danmakuRows', '${v.round()}'),
                      ),
                      _slider(
                        label: '同屏上限',
                        value: maxOnScreen,
                        min: 10,
                        max: 500,
                        divisions: 49,
                        format: (v) => '${v.round()}',
                        onChanging: (v) => setState(() => _s['danmakuMaxOnScreen'] = '${v.round()}'),
                        onCommit: (v) => _set('danmakuMaxOnScreen', '${v.round()}'),
                      ),
                      _slider(
                        label: '滚动区域',
                        value: scrollArea,
                        min: 10,
                        max: 100,
                        divisions: 18,
                        format: (v) => '${v.round()}%',
                        onChanging: (v) => setState(() => _s['danmakuScrollArea'] = '${v.round()}'),
                        onCommit: (v) => _set('danmakuScrollArea', '${v.round()}'),
                      ),
                      _slider(
                        label: '水平间距',
                        value: (double.tryParse(g('danmakuScrollGap', '8')) ?? 8).clamp(0.0, 20.0),
                        min: 0,
                        max: 20,
                        divisions: 20,
                        format: (v) => '${v.round()}%',
                        onChanging: (v) => setState(() => _s['danmakuScrollGap'] = '${v.round()}'),
                        onCommit: (v) => _set('danmakuScrollGap', '${v.round()}'),
                      ),
                      _slider(
                        label: '时轴偏移',
                        value: offset,
                        min: -300000,
                        max: 300000,
                        divisions: 120,
                        format: (v) {
                          final s = (v / 1000).round();
                          if (s == 0) return '0 s';
                          return s > 0 ? '+$s s' : '$s s';
                        },
                        onChanging: (v) => setState(() => _s['danmakuOffsetMs'] = '${v.round()}'),
                        onCommit: (v) => _set('danmakuOffsetMs', '${v.round()}'),
                      ),
                      _toggle('滚动弹幕', flag('danmakuShowScroll'), (v) => _set('danmakuShowScroll', v ? 'true' : 'false')),
                      _toggle('顶部弹幕', flag('danmakuShowTop'), (v) => _set('danmakuShowTop', v ? 'true' : 'false')),
                      _toggle('底部弹幕', flag('danmakuShowBottom'), (v) => _set('danmakuShowBottom', v ? 'true' : 'false')),
                      _toggle('逆向弹幕', flag('danmakuShowReverse'), (v) => _set('danmakuShowReverse', v ? 'true' : 'false')),
                      _toggle('定位弹幕', flag('danmakuShowPositioned'), (v) => _set('danmakuShowPositioned', v ? 'true' : 'false')),
                      _toggle('特殊弹幕', flag('danmakuShowSpecial'), (v) => _set('danmakuShowSpecial', v ? 'true' : 'false')),
                      _toggle('粗体', flag('danmakuBold', false), (v) => _set('danmakuBold', v ? 'true' : 'false')),
                      _nav(
                        '描边样式',
                        switch (g('danmakuStrokeMode', 'shadow').trim().toLowerCase()) {
                          'none' => '无',
                          'outline' => '描边',
                          'projection' => '投影',
                          _ => '阴影',
                        },
                        () async {
                          final cur = g('danmakuStrokeMode', 'shadow').trim().toLowerCase();
                          final picked = await pickChoice(context, title: '弹幕描边', current: cur, options: const [
                            ('无', 'none'),
                            ('描边', 'outline'),
                            ('阴影', 'shadow'),
                            ('投影', 'projection'),
                          ]);
                          if (picked != null) await _set('danmakuStrokeMode', picked);
                        },
                      ),
                      if (g('danmakuStrokeMode', 'shadow').trim().toLowerCase() == 'outline')
                        _slider(
                          label: '描边宽度',
                          value: ((double.tryParse(g('danmakuStrokeWidth', '0.12')) ?? 0.12) * 100).clamp(5.0, 30.0),
                          min: 5,
                          max: 30,
                          divisions: 25,
                          format: (v) => '${(v / 100).toStringAsFixed(2)}×',
                          onChanging: (v) => setState(() => _s['danmakuStrokeWidth'] = (v / 100).toStringAsFixed(2)),
                          onCommit: (v) => _set('danmakuStrokeWidth', (v / 100).toStringAsFixed(2)),
                        ),
                      if (g('danmakuStrokeMode', 'shadow').trim().toLowerCase() == 'shadow')
                        _slider(
                          label: '阴影透明度',
                          value: ((double.tryParse(g('danmakuShadowOpacity', '0.5')) ?? 0.5) * 100).clamp(0.0, 90.0),
                          min: 0,
                          max: 90,
                          divisions: 18,
                          format: (v) => '${v.round()}%',
                          onChanging: (v) => setState(() => _s['danmakuShadowOpacity'] = (v / 100).toStringAsFixed(2)),
                          onCommit: (v) => _set('danmakuShadowOpacity', (v / 100).toStringAsFixed(2)),
                        ),
                      if (g('danmakuStrokeMode', 'shadow').trim().toLowerCase() == 'projection') ...[
                        _slider(
                          label: '投影偏移 X',
                          value: ((double.tryParse(g('danmakuProjectionOffsetX', '0.08')) ?? 0.08) * 100).clamp(2.0, 15.0),
                          min: 2,
                          max: 15,
                          divisions: 13,
                          format: (v) => '${(v / 100).toStringAsFixed(2)}×',
                          onChanging: (v) => setState(() => _s['danmakuProjectionOffsetX'] = (v / 100).toStringAsFixed(2)),
                          onCommit: (v) => _set('danmakuProjectionOffsetX', (v / 100).toStringAsFixed(2)),
                        ),
                        _slider(
                          label: '投影偏移 Y',
                          value: ((double.tryParse(g('danmakuProjectionOffsetY', '0.08')) ?? 0.08) * 100).clamp(2.0, 15.0),
                          min: 2,
                          max: 15,
                          divisions: 13,
                          format: (v) => '${(v / 100).toStringAsFixed(2)}×',
                          onChanging: (v) => setState(() => _s['danmakuProjectionOffsetY'] = (v / 100).toStringAsFixed(2)),
                          onCommit: (v) => _set('danmakuProjectionOffsetY', (v / 100).toStringAsFixed(2)),
                        ),
                        _slider(
                          label: '投影透明度',
                          value: ((double.tryParse(g('danmakuProjectionOpacity', '0.2')) ?? 0.2) * 100).clamp(0.0, 90.0),
                          min: 0,
                          max: 90,
                          divisions: 18,
                          format: (v) => '${v.round()}%',
                          onChanging: (v) => setState(() => _s['danmakuProjectionOpacity'] = (v / 100).toStringAsFixed(2)),
                          onCommit: (v) => _set('danmakuProjectionOpacity', (v / 100).toStringAsFixed(2)),
                        ),
                      ],
                      _nav(
                        '颜色策略',
                        switch (g('danmakuColorMode', 'original').trim().toLowerCase()) {
                          'white' => '白色',
                          'yellow' => '黄色',
                          _ => '原色',
                        },
                        () async {
                          final cur = g('danmakuColorMode', 'original').trim().toLowerCase();
                          final picked = await pickChoice(context, title: '弹幕颜色', current: cur, options: const [
                            ('保留原色', 'original'),
                            ('白色', 'white'),
                            ('黄色', 'yellow'),
                          ]);
                          if (picked != null) await _set('danmakuColorMode', picked);
                        },
                      ),
                      _nav(
                        '弹幕字体',
                        switch (g('danmakuFont', 'default').trim().toLowerCase()) {
                          'sans' || 'sans-serif' => '无衬线',
                          'serif' => '衬线',
                          'mono' || 'monospace' => '等宽',
                          _ => '默认',
                        },
                        () async {
                          final cur = g('danmakuFont', 'default').trim().toLowerCase();
                          final picked = await pickChoice(
                            context,
                            title: '弹幕字体',
                            current: cur == 'sans-serif' ? 'sans' : (cur == 'monospace' ? 'mono' : cur),
                            options: const [
                              ('默认', 'default'),
                              ('无衬线', 'sans'),
                              ('衬线', 'serif'),
                              ('等宽', 'mono'),
                            ],
                          );
                          if (picked != null) await _set('danmakuFont', picked);
                        },
                      ),
                      _slider(
                        label: '顶部行数',
                        value: (double.tryParse(g('danmakuRowsTop', '3')) ?? 3).clamp(1, 8),
                        min: 1,
                        max: 8,
                        divisions: 7,
                        format: (v) => '${v.round()}',
                        onChanging: (v) => setState(() => _s['danmakuRowsTop'] = '${v.round()}'),
                        onCommit: (v) => _set('danmakuRowsTop', '${v.round()}'),
                      ),
                      _slider(
                        label: '底部行数',
                        value: (double.tryParse(g('danmakuRowsBottom', '3')) ?? 3).clamp(1, 8),
                        min: 1,
                        max: 8,
                        divisions: 7,
                        format: (v) => '${v.round()}',
                        onChanging: (v) => setState(() => _s['danmakuRowsBottom'] = '${v.round()}'),
                        onCommit: (v) => _set('danmakuRowsBottom', '${v.round()}'),
                      ),
                      _slider(
                        label: '滚动时长',
                        value: (double.tryParse(g('danmakuDurationMs', '8000')) ?? 8000).clamp(3000, 15000),
                        min: 3000,
                        max: 15000,
                        divisions: 24,
                        format: (v) => '${(v / 1000).toStringAsFixed(1)} s',
                        onChanging: (v) => setState(() => _s['danmakuDurationMs'] = '${v.round()}'),
                        onCommit: (v) => _set('danmakuDurationMs', '${v.round()}'),
                      ),
                      _slider(
                        label: '固定时长',
                        value: (double.tryParse(g('danmakuFixedDurationMs', '5000')) ?? 5000).clamp(2000, 10000),
                        min: 2000,
                        max: 10000,
                        divisions: 16,
                        format: (v) => '${(v / 1000).toStringAsFixed(1)} s',
                        onChanging: (v) => setState(() => _s['danmakuFixedDurationMs'] = '${v.round()}'),
                        onCommit: (v) => _set('danmakuFixedDurationMs', '${v.round()}'),
                      ),
                      _slider(
                        label: '行距',
                        value: (double.tryParse(g('danmakuLineSpacing', '1.4')) ?? 1.4).clamp(1.0, 2.0),
                        min: 1.0,
                        max: 2.0,
                        divisions: 10,
                        format: (v) => v.toStringAsFixed(1),
                        onChanging: (v) => setState(() => _s['danmakuLineSpacing'] = v.toStringAsFixed(1)),
                        onCommit: (v) => _set('danmakuLineSpacing', v.toStringAsFixed(1)),
                      ),
                    ],
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
