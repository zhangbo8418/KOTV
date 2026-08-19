import 'package:flutter/material.dart';

/// Web / 无 AndroidView 的平台：Exo 不会真正开播。
Widget kotvExoSurfaceView({
  required String viewType,
  required String fitName,
  required void Function(String fitName) onFit,
}) {
  return const ColoredBox(color: Colors.black);
}
