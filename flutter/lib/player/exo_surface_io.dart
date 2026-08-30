import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

/// Exo 画面平台视图。
///
/// - [hybrid]=true：Hybrid Composition + SurfaceView（对齐 TV，HDR 直出）
/// - [hybrid]=false：Virtual Display（兼容路径；HDR/10bit 可能异常）
Widget kotvExoSurfaceView({
  Key? key,
  required String viewType,
  required String fitName,
  required void Function(String fitName) onFit,
  bool hybrid = false,
}) {
  onFit(fitName);
  final params = <String, dynamic>{'fit': fitName};
  if (hybrid) {
    return PlatformViewLink(
      key: key,
      viewType: viewType,
      surfaceFactory: (context, controller) {
        return AndroidViewSurface(
          controller: controller as AndroidViewController,
          hitTestBehavior: PlatformViewHitTestBehavior.transparent,
          gestureRecognizers: const <Factory<OneSequenceGestureRecognizer>>{},
        );
      },
      onCreatePlatformView: (p) {
        final controller = PlatformViewsService.initExpensiveAndroidView(
          id: p.id,
          viewType: viewType,
          layoutDirection: TextDirection.ltr,
          creationParams: params,
          creationParamsCodec: const StandardMessageCodec(),
        );
        controller.addOnPlatformViewCreatedListener(p.onPlatformViewCreated);
        controller.create();
        return controller;
      },
    );
  }
  // Virtual Display：API 24/25 盒子上 Hybrid dispose 易触发 RenderObject.detach 断言。
  return AndroidView(
    key: key,
    viewType: viewType,
    layoutDirection: TextDirection.ltr,
    creationParams: params,
    creationParamsCodec: const StandardMessageCodec(),
    hitTestBehavior: PlatformViewHitTestBehavior.transparent,
  );
}
