import 'dart:io';

/// Checks that keep every package at 160 pub points (Blueprint #55).
///
/// ```bash
/// dart run tool/publish_checks.dart                         # CI, release.dart
/// dart run tool/publish_checks.dart --ready packages/<pkg>  # before a manual publish
/// ```
///
/// Without arguments it checks the repository: every published package
/// has an `example/` (10 points) and a job in `.github/workflows/publish.yml`
/// whose `needs:` reach the jobs of the workspace packages it depends on,
/// so pub.dev never analyses it before they exist (a package analysed
/// without its dependencies scores 50).
///
/// `--ready packages/<pkg>` asks pub.dev whether the versions its
/// workspace dependencies require are published, for the first, manual
/// publish of a new package: publish only when it says so.
Future<void> main(List<String> args) async {
  final ready = args.indexOf('--ready');
  if (ready >= 0) {
    if (ready + 1 >= args.length) {
      stderr.writeln(
        'Usage: dart run tool/publish_checks.dart --ready packages/<pkg>',
      );
      exitCode = 64;
      return;
    }
    exitCode = await _ready(args[ready + 1]);
    return;
  }
  final problems = publishProblems(Directory.current.path);
  if (problems.isEmpty) {
    stdout.writeln(
      'Every published package has an example and a publish job after its dependencies.',
    );
    return;
  }
  for (final problem in problems) {
    stderr.writeln('- $problem');
  }
  exitCode = 1;
}

/// What stands between the packages under [root] and 160 points.
List<String> publishProblems(String root) {
  final packages = _publishedPackages(root);
  final names = packages.keys.toSet();
  final workflow = File('$root/.github/workflows/publish.yml');
  final jobs = workflow.existsSync()
      ? _publishJobs(workflow.readAsStringSync())
      : <String, _Job>{};
  final jobOf = {for (final job in jobs.values) job.package: job};
  final problems = <String>[];
  for (final MapEntry(key: name, value: pubspec) in packages.entries) {
    final dir = '$root/packages/$name';
    final example = Directory('$dir/example');
    if (!example.existsSync() ||
        !example
            .listSync(recursive: true)
            .any((f) => f.path.endsWith('.dart'))) {
      problems.add(
        'packages/$name has no example/*.dart (pub.dev: -10 points).',
      );
    }
    final job = jobOf['packages/$name'];
    if (job == null) {
      problems.add(
        'packages/$name has no job in .github/workflows/publish.yml: the '
        'release would not publish it.',
      );
      continue;
    }
    for (final dependency in _workspaceDependencies(pubspec, names)) {
      final target = jobOf['packages/$dependency'];
      if (target == null) {
        continue;
      }
      if (!_reaches(job, target.name, jobs)) {
        problems.add(
          'The publish job ${job.name} does not wait for ${target.name}: '
          'packages/$name depends on $dependency.',
        );
      }
    }
  }
  return problems;
}

/// Published workspace packages (no `publish_to: none`): name → pubspec.
Map<String, String> _publishedPackages(String root) {
  final result = <String, String>{};
  final dir = Directory('$root/packages');
  for (final entry
      in dir.listSync()..sort((a, b) => a.path.compareTo(b.path))) {
    final pubspec = File('${entry.path}/pubspec.yaml');
    if (entry is! Directory || !pubspec.existsSync()) {
      continue;
    }
    final text = pubspec.readAsStringSync();
    if (RegExp(r'^publish_to:\s*none', multiLine: true).hasMatch(text)) {
      continue;
    }
    final name = RegExp(
      r'^name:\s*(\S+)',
      multiLine: true,
    ).firstMatch(text)![1]!;
    result[name] = text;
  }
  return result;
}

/// The workspace packages [pubspec] depends on (not dev dependencies:
/// pana resolves those too, but they are published in the same run and
/// a cycle through dev dependencies is allowed).
Iterable<String> _workspaceDependencies(String pubspec, Set<String> names) {
  final section = RegExp(
    r'^dependencies:\n((?:[ \t]+.*\n?|\n)*)',
    multiLine: true,
  ).firstMatch(pubspec)?[1];
  if (section == null) {
    return const [];
  }
  return [
    for (final match in RegExp(
      r'^  ([a-z0-9_]+):',
      multiLine: true,
    ).allMatches(section))
      if (names.contains(match[1])) match[1]!,
  ];
}

final class _Job {
  _Job(this.name, this.needs, this.package);
  final String name;
  final List<String> needs;
  final String package;
}

/// The publish jobs of publish.yml: job name, its `needs:` and the
/// `working-directory` it publishes.
Map<String, _Job> _publishJobs(String workflow) {
  final jobs = <String, _Job>{};
  final blocks = RegExp(
    r'^  ([a-z0-9_]+):\n((?:    .*\n?|\n)*)',
    multiLine: true,
  );
  for (final block in blocks.allMatches(workflow)) {
    final body = block[2]!;
    final directory = RegExp(r'working-directory:\s*(\S+)')
        .firstMatch(body)?[1];
    if (directory == null) {
      continue;
    }
    final needs =
        RegExp(r'needs:\s*\[([^\]]*)\]').firstMatch(body)?[1] ??
        RegExp(r'needs:\s*(\S+)').firstMatch(body)?[1] ??
        '';
    jobs[block[1]!] = _Job(block[1]!, [
      for (final n in needs.split(','))
        if (n.trim().isNotEmpty) n.trim(),
    ], directory);
  }
  return jobs;
}

/// Whether [job] waits for [target], directly or through other jobs.
bool _reaches(
  _Job job,
  String target,
  Map<String, _Job> jobs, [
  Set<String>? seen,
]) {
  final visited = seen ?? <String>{};
  for (final need in job.needs) {
    if (need == target) {
      return true;
    }
    final next = jobs[need];
    if (next != null &&
        visited.add(need) &&
        _reaches(next, target, jobs, visited)) {
      return true;
    }
  }
  return false;
}

/// `--ready`: whether every workspace dependency of [package] is on
/// pub.dev at the version its constraint asks for.
Future<int> _ready(String package) async {
  final root = Directory.current.path;
  final packages = _publishedPackages(root);
  final pubspecFile = File(
    '$root/${package.replaceAll(r'\', '/')}/pubspec.yaml',
  );
  if (!pubspecFile.existsSync()) {
    stderr.writeln('No pubspec.yaml in $package.');
    return 64;
  }
  final pubspec = pubspecFile.readAsStringSync();
  final client = HttpClient();
  var missing = 0;
  try {
    for (final dependency in _workspaceDependencies(
      pubspec,
      packages.keys.toSet(),
    )) {
      final constraint = RegExp(
        '^  $dependency:\\s*\\^?(\\S+)',
        multiLine: true,
      ).firstMatch(pubspec)?[1];
      if (constraint == null || constraint == 'any') {
        continue;
      }
      final request = await client.getUrl(
        Uri.parse(
          'https://pub.dev/api/packages/$dependency/versions/$constraint',
        ),
      );
      final response = await request.close();
      await response.drain<void>();
      final live = response.statusCode == 200;
      stdout.writeln('${live ? 'ok     ' : 'MISSING'} $dependency $constraint');
      if (!live) {
        missing++;
      }
    }
  } finally {
    client.close(force: true);
  }
  if (missing > 0) {
    stderr.writeln(
      'Not ready: publish the dependencies first (the release tag does), '
      'or pub.dev analyses $package without them and scores it 50/160.',
    );
    return 1;
  }
  stdout.writeln('Ready: $package can be published.');
  return 0;
}
