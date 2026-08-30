import 'package:flutter/material.dart';

/// Web / 无 AndroidView 的平台占位。
Widget kotvMpvSurfaceView({
  Key? key,
  required String viewType,
  bool hybrid = true,
}) {
  return const ColoredBox(color: Colors.black);
}
