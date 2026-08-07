/// 条件导入：Web 用 stub，其它平台用 dart:io。
export 'kotv_io_io.dart' if (dart.library.html) 'kotv_io_stub.dart';
