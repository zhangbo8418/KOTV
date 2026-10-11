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
///
/// [androidSurface]：安卓 Surface（tunnel）用 `image=0` 直出；Texture（非 tunnel）用默认 AMediaCodec。
List<String> kotvFvpVideoDecoders(
  String decodeMode, {
  bool androidSurface = true,
}) {
  final m = decodeMode.trim().toLowerCase();
  final soft = m == 'soft' || m == 'software' || m == 'sw';
  final hard = m == 'hard' || m == 'hardware' || m == 'hw';
  if (soft) return const ['FFmpeg', 'dav1d'];

  final withSoft = !hard;
  List<String> appendSoft(List<String> hw) =>
      withSoft ? [...hw, 'FFmpeg', 'dav1d'] : hw;

  if (kotvIsAndroid()) {
    // Surface/tunnel：image=0 解码到 Surface。Texture：默认 AMediaCodec（经 GL）。
    return appendSoft([
      androidSurface ? 'AMediaCodec:image=0' : 'AMediaCodec',
    ]);
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
    // Win7：先 DXVA（d3d9）。勿把 FFmpeg D3D11/d3d11va 放进列表——ID3D11VideoDevice
    // 最低 Win8（MSDN），历史上摸到会黑屏/卡平台线程。MFT:d3d=11 为 mdk 自研且文档
    // 标 win7+，但 shared/shader_resource 仅 win8+；fallback=0 失败必须返回，才能试下
    // 一个或落到自动模式的 FFmpeg/dav1d。渲染侧 d3d11.device/copy=0 与 Win7 无关（图形 API）。
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
