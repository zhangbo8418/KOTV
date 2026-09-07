import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

/// 原生 MPV Surface PlatformView（与 Exo Hybrid Composition 一致）。
Widget kotvMpvSurfaceView({
  Key? key,
  required String viewType,
  bool hybrid = true,
}) {
  const params = <String, dynamic>{};
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
  return AndroidView(
    key: key,
    viewType: viewType,
    layoutDirection: TextDirection.ltr,
    creationParams: params,
    creationParamsCodec: const StandardMessageCodec(),
    hitTestBehavior: PlatformViewHitTestBehavior.transparent,
  );
}
