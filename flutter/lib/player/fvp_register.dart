/// FVP / libmdk 注册；Web 无 dart:ffi，回落 no-op。
export 'fvp_register_io.dart' if (dart.library.html) 'fvp_register_stub.dart';
