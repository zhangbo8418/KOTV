/// Android SurfaceView 平台视图；Web 无此 API，走 stub。
export 'mpv_surface_io.dart' if (dart.library.html) 'mpv_surface_stub.dart';
