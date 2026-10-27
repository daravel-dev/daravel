import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';

import 'generator.dart' show ProjectPaths;

import 'package:path/path.dart' as p;

import 'project_commands.dart' show dartExecutable;

/// The packages released together under one version.
const List<String> daravelPackages = [
  'daravel',
  'dartisan_cli',
  'daravel_test',
  'daravel_lints',
  'daravel_mysql',
  'daravel_sqlite',
  'daravel_postgres',
  'daravel_permission',
  'daravel_redis',
  'daravel_teorion',
  'daravel_livekit',
  'daravel_s3',
];

/// Reads the latest stable `daravel` version from pub.dev.
typedef LatestVersion = Future<String> Function();

/// Runs `dart <args>` in a directory and returns its exit code.
typedef DartRunner = Future<int> Function(
  List<String> args, {
  String? workingDirectory,
});

Future<String> pubDevLatest() async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
  try {
    final request = await client.getUrl(
      Uri.parse('https://pub.dev/api/packages/daravel'),
    );
    request.headers.set('accept', 'application/vnd.pub.v2+json');
    final response = await request.close().timeout(const Duration(seconds: 10));
    final body = await response.transform(utf8.decoder).join();
    if (response.statusCode != 200) {
      throw HttpException('pub.dev answered ${response.statusCode}.');
    }
    final latest =
        (jsonDecode(body) as Map<String, Object?>)['latest']!
            as Map<String, Object?>;
    return latest['version']! as String;
  } finally {
    client.close(force: true);
  }
}

Future<int> runDart(List<String> args, {String? workingDirectory}) async {
  final process = await Process.start(
    dartExecutable(),
    args,
    workingDirectory: workingDirectory,
    mode: ProcessStartMode.inheritStdio,
  );
  return process.exitCode;
}

/// The result of [rewriteConstraints].
typedef ConstraintRewrite = ({
  String pubspec,
  List<String> updated,
  List<String> local,
});

/// Sets the hosted constraint of every Daravel package in `dependencies`
/// and `dev_dependencies` to `^version`. Packages from `git:` or `path:`
/// are listed in `local` and left alone, and so is `dependency_overrides`.
ConstraintRewrite rewriteConstraints(String pubspec, String version) {
  final lines = const LineSplitter().convert(pubspec);
  final updated = <String>[];
  final local = <String>[];
  String? section;
  final entry = RegExp(r'^(\s+)([a-z_][a-z0-9_]*):\s*(.*?)\s*$');
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    if (line.isNotEmpty && !line.startsWith(' ') && !line.startsWith('#')) {
      section = line.split(':').first.trim();
      continue;
    }
    if (section != 'dependencies' && section != 'dev_dependencies') {
      continue;
    }
    final match = entry.firstMatch(line);
    if (match == null || !daravelPackages.contains(match[2])) {
      continue;
    }
    final indent = match[1]!;
    final value = match[3]!;
    if (value.isNotEmpty) {
      lines[i] = '$indent${match[2]}: ^$version';
      updated.add(match[2]!);
      continue;
    }
    // A map: `version:` is rewritten, `git:` or `path:` is a local copy.
    var j = i + 1;
    int? versionLine;
    var isLocal = false;
    while (j < lines.length &&
        (lines[j].trim().isEmpty ||
            lines[j].length - lines[j].trimLeft().length > indent.length)) {
      final key = lines[j].trim().split(':').first;
      if (key == 'git' || key == 'path') {
        isLocal = true;
      } else if (key == 'version') {
        versionLine = j;
      }
      j++;
    }
    if (isLocal) {
      local.add(match[2]!);
    } else if (versionLine != null) {
      final own = lines[versionLine];
      lines[versionLine] =
          '${own.substring(0, own.length - own.trimLeft().length)}'
          'version: ^$version';
      updated.add(match[2]!);
    }
  }
  final ending = pubspec.endsWith('\n') ? '\n' : '';
  return (
    pubspec: '${lines.join('\n')}$ending',
    updated: updated,
    local: local,
  );
}

/// The `daravel` version in `pubspec.lock`, or null.
String? lockedVersion(String lock) => RegExp(
  r'^  daravel:\n(?:    .*\n)*?    version: "([^"]+)"',
  multiLine: true,
).firstMatch(lock)?[1];

/// `dartisan upgrade`: moves a project, and the global CLI, to a Daravel
/// release (BLUEPRINT #12).
final class UpgradeCommand extends Command<int> {
  UpgradeCommand({LatestVersion? latest, DartRunner? dart})
    : _latest = latest ?? pubDevLatest,
      _dart = dart ?? runDart {
    argParser
      ..addFlag(
        'check',
        negatable: false,
        help: 'Show the installed and the latest version; change nothing.',
      )
      ..addOption('to', help: 'The version to move to (default: the latest).')
      ..addFlag(
        'global',
        defaultsTo: true,
        help: 'Also activate the same version of the global dartisan.',
      )
      ..addFlag('get', defaultsTo: true, help: 'Run `dart pub upgrade`.');
  }

  final LatestVersion _latest;
  final DartRunner _dart;

  @override
  String get name => 'upgrade';

  @override
  String get description =>
      'Upgrade the project to the latest Daravel release (all packages).';

  @override
  Future<int> run() async {
    final root = ProjectPaths.locate().root;
    final pubspecFile = File(p.join(root, 'pubspec.yaml'));
    final lock = _lockFile(root);
    final current = lock == null
        ? null
        : lockedVersion(lock.readAsStringSync());
    final String target;
    try {
      target = argResults!['to'] as String? ?? await _latest();
    } on Object catch (error) {
      stderr.writeln(
        'Could not read the latest version from pub.dev ($error). '
        'Pass --to=<version> to choose one.',
      );
      return 1;
    }
    if (!RegExp(r'^\d+\.\d+\.\d+(-[\w.]+)?$').hasMatch(target)) {
      stderr.writeln('"$target" is not a version such as 1.9.0.');
      return 64;
    }
    stdout.writeln('Installed: ${current ?? 'unknown'}   Latest: $target');
    if (argResults!['check'] as bool) {
      return 0;
    }

    final rewrite = rewriteConstraints(pubspecFile.readAsStringSync(), target);
    if (rewrite.local.isNotEmpty) {
      stdout.writeln(
        'From git or a path, not changed: ${rewrite.local.join(', ')}.',
      );
    }
    if (rewrite.updated.isNotEmpty) {
      pubspecFile.writeAsStringSync(rewrite.pubspec);
      stdout.writeln('pubspec.yaml: ${rewrite.updated.join(', ')} → ^$target');
    }
    if (argResults!['get'] as bool) {
      final code = await _dart(['pub', 'upgrade'], workingDirectory: root);
      if (code != 0) {
        return code;
      }
    }
    if (argResults!['global'] as bool) {
      final code = await _dart([
        'pub',
        'global',
        'activate',
        'dartisan_cli',
        target,
      ]);
      if (code != 0) {
        stderr.writeln(
          'The project is upgraded; the global dartisan is not '
          '(dart pub global activate dartisan_cli $target).',
        );
        return code;
      }
    }
    stdout.writeln(
      'Upgraded to Daravel $target. See the changelog: '
      'https://github.com/daravel-dev/daravel/blob/main/CHANGELOG.md',
    );
    return 0;
  }
}

/// The project's `pubspec.lock`, or its pub workspace's.
File? _lockFile(String root) {
  var dir = Directory(root).absolute;
  while (true) {
    final lock = File(p.join(dir.path, 'pubspec.lock'));
    if (lock.existsSync()) {
      return lock;
    }
    if (dir.parent.path == dir.path) {
      return null;
    }
    dir = dir.parent;
  }
}

/// `dartisan self-update`: activates the latest (or `--to`) global
/// `dartisan_cli`.
final class SelfUpdateCommand extends Command<int> {
  SelfUpdateCommand({DartRunner? dart}) : _dart = dart ?? runDart {
    argParser.addOption('to', help: 'The version to activate.');
  }

  final DartRunner _dart;

  @override
  String get name => 'self-update';

  @override
  String get description => 'Update the global dartisan.';

  @override
  Future<int> run() => _dart([
    'pub',
    'global',
    'activate',
    'dartisan_cli',
    if (argResults!['to'] case final String version) version,
  ]);
}
