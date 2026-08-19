import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

/// Hybrid Composition + SurfaceView：对齐 TV HDR，避免 Texture 转 SDR 发暗。
Widget kotvExoSurfaceView({
  required String viewType,
  required String fitName,
  required void Function(String fitName) onFit,
}) {
  onFit(fitName);
  return PlatformViewLink(
    viewType: viewType,
    surfaceFactory: (context, controller) {
      return AndroidViewSurface(
        controller: controller as AndroidViewController,
        hitTestBehavior: PlatformViewHitTestBehavior.transparent,
        gestureRecognizers: const <Factory<OneSequenceGestureRecognizer>>{},
      );
    },
    onCreatePlatformView: (params) {
      final controller = PlatformViewsService.initExpensiveAndroidView(
        id: params.id,
        viewType: viewType,
        layoutDirection: TextDirection.ltr,
        creationParams: <String, dynamic>{'fit': fitName},
        creationParamsCodec: const StandardMessageCodec(),
      );
      controller.addOnPlatformViewCreatedListener(params.onPlatformViewCreated);
      controller.create();
      return controller;
    },
  );
}
