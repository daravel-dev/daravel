import 'dart:io';

/// Runs the Dart program [script] (a path from the current directory, as a
/// test's) as a process of its own, with [arguments] and [environment], and
/// returns how it ended: for a test of what only a process shows (its
/// output after a shutdown, its exit code).
///
/// It runs on the bare VM (`dartvm`, beside the `dart` running the test)
/// with the workspace's `.dart_tool/package_config.json`, not through
/// `dart run`: `dart run` runs the build hooks and copies the native
/// assets again, and on Windows a test runner that has already opened
/// SQLite holds `.dart_tool/lib/sqlite3.dll`, so that copy fails. The VM
/// finds the assets the hooks built before. Without a `dartvm` (an SDK
/// before it shipped one), it falls back to `dart run`.
Future<ProcessResult> runDartScript(
  String script, {
  List<String> arguments = const [],
  Map<String, String>? environment,
}) {
  final dart = File(Platform.resolvedExecutable);
  final vm = File(
    '${dart.parent.path}${Platform.pathSeparator}'
    'dartvm${Platform.isWindows ? '.exe' : ''}',
  );
  final packages = _packageConfig(Directory.current);
  if (!vm.existsSync() || packages == null) {
    return Process.run(dart.path, [
      'run',
      script,
      ...arguments,
    ], environment: environment);
  }
  return Process.run(vm.path, [
    '--packages=${packages.path}',
    script,
    ...arguments,
  ], environment: environment);
}

/// The nearest `.dart_tool/package_config.json` from [from] up (a pub
/// workspace keeps one at its root).
File? _packageConfig(Directory from) {
  for (Directory? dir = from.absolute; dir != null;) {
    final config = File(
      '${dir.path}${Platform.pathSeparator}.dart_tool'
      '${Platform.pathSeparator}package_config.json',
    );
    if (config.existsSync()) {
      return config;
    }
    final parent = dir.parent;
    dir = parent.path == dir.path ? null : parent;
  }
  return null;
}
