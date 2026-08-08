/// Web 最小 dart:io stub（仅覆盖本项目用到的 Platform / 少量 File API）。
class Platform {
  static bool get isAndroid => false;
  static bool get isIOS => false;
  static bool get isMacOS => false;
  static bool get isWindows => false;
  static bool get isLinux => false;
  static bool get isFuchsia => false;
  static String get pathSeparator => '/';
  static String get operatingSystem => 'web';
  static String get operatingSystemVersion => '';
  static String get localeName => 'en';
  static String get localHostname => 'localhost';
  static int get numberOfProcessors => 1;
  static String get resolvedExecutable => '';
  static String get script => '';
  static String get executable => '';
  static List<String> get executableArguments => const [];
  static String? get packageConfig => null;
  static Uri get scriptUri => Uri.parse('https://localhost/');
  static Map<String, String> get environment => const {};
}

class File {
  File(this.path);
  final String path;
  bool existsSync() => false;
  Future<bool> exists() async => false;
  Future<String> readAsString({encoding}) async => '';
  String readAsStringSync({encoding}) => '';
  Future<File> writeAsString(String contents, {encoding, mode, flush}) async => this;
  void writeAsStringSync(String contents, {encoding, mode, flush}) {}
  Future<int> length() async => 0;
  int lengthSync() => 0;
  Future<FileStat> stat() async => FileStat._();
  FileStat statSync() => FileStat._();
}

class Directory {
  Directory(this.path);
  final String path;
  static Directory get current => Directory('.');
  static Directory get systemTemp => Directory('/tmp');
  bool existsSync() => false;
  Future<bool> exists() async => false;
  Future<Directory> create({bool recursive = false}) async => this;
  void createSync({bool recursive = false}) {}
  Stream<FileSystemEntity> list({bool recursive = false, bool followLinks = true}) =>
      const Stream.empty();
}

class FileSystemEntity {
  String get path => '';
}

class FileStat {
  FileStat._();
  int get size => 0;
  DateTime get modified => DateTime.fromMillisecondsSinceEpoch(0);
}

class Process {
  static Future<ProcessResult> run(String executable, List<String> arguments,
          {String? workingDirectory, Map<String, String>? environment, bool includeParentEnvironment = true, bool runInShell = false, encoding, stderrEncoding}) async =>
      ProcessResult(0, 1, '', 'unsupported on web');
  static Future<Process> start(String executable, List<String> arguments,
          {String? workingDirectory, Map<String, String>? environment, bool includeParentEnvironment = true, bool runInShell = false, ProcessStartMode mode = ProcessStartMode.normal}) async =>
      throw UnsupportedError('Process.start unsupported on web');
}

class ProcessResult {
  ProcessResult(this.pid, this.exitCode, this.stdout, this.stderr);
  final int pid;
  final int exitCode;
  final dynamic stdout;
  final dynamic stderr;
}

enum ProcessStartMode { normal, detached, detachedWithStdio }

/// 对齐 dart:io FileMode，供 writeAsStringSync 命名参数在 Web 编译期解析。
enum FileMode { read, write, append, writeOnly, writeOnlyAppend }

class ProcessSignal {
  static const ProcessSignal sigterm = ProcessSignal._();
  static const ProcessSignal sigkill = ProcessSignal._();
  const ProcessSignal._();
}

class HttpClient {
  Future<HttpClientRequest> getUrl(Uri url) async => throw UnsupportedError('use package:http on web');
  Future<HttpClientRequest> openUrl(String method, Uri url) async => throw UnsupportedError('use package:http on web');
  void close({bool force = false}) {}
}

abstract class HttpClientRequest {
  Future<HttpClientResponse> close();
}

abstract class HttpClientResponse {
  int get statusCode;
}

Never exit(int code) => throw UnsupportedError('exit unsupported on web');
