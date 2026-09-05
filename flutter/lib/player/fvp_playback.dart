/// 页内 FVP（libmdk）；Web 无 dart:ffi，回落 stub。
export 'fvp_playback_io.dart' if (dart.library.html) 'fvp_playback_stub.dart';
