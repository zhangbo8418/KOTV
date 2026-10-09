import 'package:flutter/foundation.dart';

import 'kotv_platform.dart';

/// FVP / libmdk 视频解码器列表（与设置「自动 / 硬解 / 软解」一致）。
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
    // 默认 image=1 走 AImageReader。MTK C2 会报 Client returned a buffer it does not own，
    // 输入大约一秒才进几帧。image=0 关掉这条读回路径，解码器按帧间隔取输入。
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
    // Win7：D3D11 视频解码不稳，优先 DXVA2（MFT d3d=9 / DXVA）。
    if (kotvIsWindows7()) {
      return appendSoft(const ['MFT:d3d=9', 'DXVA', 'hap']);
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
