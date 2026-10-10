import 'package:flutter/foundation.dart';

import 'kotv_platform.dart';

/// FVP / libmdk 视频解码器列表（自动 / 硬解 / 软解）。
///
/// 这个列表必须交给 registerWith 的 `video.decoders`。插件 create 在 prepare
/// 之前读取它；initialize 之前调用 setVideoDecoders 没有 player，不会生效。
/// 不传时插件默认是 Windows `MFT:d3d=11`、Android 不带参数的 `AMediaCodec`。
///
/// - **自动**：硬解优先 + FFmpeg/dav1d 回退
/// - **硬解**：仅平台硬解，不带软解回退
/// - **软解**：仅 FFmpeg（+ dav1d）
List<String> kotvFvpVideoDecoders(String decodeMode) {
  final m = decodeMode.trim().toLowerCase();
  final soft = m == 'soft' || m == 'software' || m == 'sw';
  final hard = m == 'hard' || m == 'hardware' || m == 'hw';
  if (soft) return const ['FFmpeg', 'dav1d'];

  final withSoft = !hard;
  List<String> appendSoft(List<String> hw) =>
      withSoft ? [...hw, 'FFmpeg', 'dav1d'] : hw;

  if (kotvIsAndroid()) {
    // image=0：解码到 Surface，不用默认的 AImageReader。
    return appendSoft(const ['AMediaCodec:image=0']);
  }
  if (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS) {
    return appendSoft(const ['VT']);
  }
  if (!kIsWeb && defaultTargetPlatform == TargetPlatform.macOS) {
    return appendSoft(const ['VT', 'hap']);
  }
  if (!kIsWeb && defaultTargetPlatform == TargetPlatform.linux) {
    return appendSoft(const ['VAAPI', 'CUDA', 'VDPAU', 'hap']);
  }
  if (!kIsWeb && defaultTargetPlatform == TargetPlatform.windows) {
    // Win7：DXVA 是 ffmpeg 的 dxva2（D3D9）。失败返回后才试 MFT d3d=11。
    // shared、shader_resource 只适用于 Win8 及以上。fallback=0 避免降到不返回失败的 d3d=9。
    if (kotvIsWindows7()) {
      return appendSoft(const [
        'DXVA',
        'MFT:d3d=11:shared=0:shader_resource=0:fallback=0',
      ]);
    }
    return appendSoft(const [
      'MFT:d3d=11',
      'D3D11',
      'DXVA',
      'CUDA',
      'hap',
    ]);
  }
  return appendSoft(const []);
}
