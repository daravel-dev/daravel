import 'dart:io';

/// Checks that keep every package at 160 pub points (Blueprint #55).
///
/// ```bash
/// dart run tool/publish_checks.dart                         # CI, release.dart
/// dart run tool/publish_checks.dart --ready packages/<pkg>  # before a manual publish
/// ```
///
/// Without arguments it checks the repository: every published package
/// has an `example/` (10 points) and a step in the one publish job of
/// `.github/workflows/publish.yml` after the steps of the workspace
/// packages it depends on, so pub.dev never analyses it before they exist
/// (a package analysed without its dependencies scores 50). The workflow
/// uses no reusable publish workflow and no artifact (see
/// [forbiddenInPublish]), and every `uses:` of the workflows in
/// [pinnedWorkflows] names a commit.
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
      'Every published package has an example and a publish step after '
      'its dependencies; the workflows pin their actions.',
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
  final text = workflow.existsSync() ? workflow.readAsStringSync() : '';
  final order = publishOrder(text);
  final problems = <String>[
    for (final construct in forbiddenInPublish(text))
      '.github/workflows/publish.yml uses $construct: publish every package '
          'from the one job instead. Parallel calls of the reusable workflow '
          'shared one artifact and published each other\'s archives in '
          '1.27.1, and a re-run downloads an older attempt\'s archive.',
  ];
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
    final position = order.indexOf('packages/$name');
    if (position < 0) {
      problems.add(
        'packages/$name has no step in .github/workflows/publish.yml: the '
        'release would not publish it.',
      );
      continue;
    }
    for (final dependency in _workspaceDependencies(pubspec, names)) {
      final before = order.indexOf('packages/$dependency');
      if (before > position) {
        problems.add(
          'In .github/workflows/publish.yml, packages/$name is published '
          'before packages/$dependency, which it depends on.',
        );
      }
    }
  }
  for (final name in pinnedWorkflows) {
    final file = File('$root/.github/workflows/$name');
    if (!file.existsSync()) {
      continue;
    }
    for (final ref in unpinnedActions(file.readAsStringSync())) {
      problems.add(
        '.github/workflows/$name uses $ref: pin it to a commit SHA. A tag '
        'such as @v1 moves; setup-dart\'s moved under the 1.27.1 release '
        'and its new workflow broke parallel publishing.',
      );
    }
  }
  return problems;
}

/// The workflows whose `uses:` must name a commit: what publishes, what
/// releases, and what CI runs before both.
const List<String> pinnedWorkflows = ['publish.yml', 'release.yml', 'ci.yml'];

/// The `uses:` references of [workflow] not pinned to a 40-character
/// commit SHA (a local `./` action is fine).
List<String> unpinnedActions(String workflow) => [
  for (final match in RegExp(
    r'^\s*(?:-\s*)?uses:\s*(\S+)',
    multiLine: true,
  ).allMatches(workflow))
    if (!match[1]!.startsWith('./') &&
        !RegExp(r'@[0-9a-f]{40}$').hasMatch(match[1]!))
      match[1]!,
];

/// The package directories [workflow] publishes, in the order of its steps
/// (each `working-directory:` line; whole lines only, as the dry-run step
/// of publish.yml reads them, so a command quoting the key is not one).
List<String> publishOrder(String workflow) => [
  for (final match in RegExp(
    r'^ +working-directory: (packages/[a-z0-9_]+)$',
    multiLine: true,
  ).allMatches(workflow))
    match[1]!,
];

/// What [workflow] must not use: setup-dart's reusable publish workflow
/// and artifact actions, which pass archives between jobs.
List<String> forbiddenInPublish(String workflow) => [
  for (final match in RegExp(
    r'^\s*(?:-\s*)?uses:\s*(\S+)',
    multiLine: true,
  ).allMatches(workflow))
    if (match[1]!.contains('/.github/workflows/') ||
        match[1]!.startsWith('actions/upload-artifact') ||
        match[1]!.startsWith('actions/download-artifact'))
      match[1]!.split('@').first,
];

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
