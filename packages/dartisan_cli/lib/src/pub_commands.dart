import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:daravel/daravel.dart' show daravelVersion;
import 'package:path/path.dart' as p;

import 'db_install.dart';
import 'generator.dart';
import 'package_registry.dart';
import 'upgrade_command.dart' show DartRunner, runDart;

/// The packages of [pubspec] and their constraints, from `dependencies`
/// and `dev_dependencies` (`path:` and `git:` entries as `path` / `git`).
Map<String, String> installedPackages(String pubspec) {
  final installed = <String, String>{};
  String? section;
  String? pending;
  for (final line in const LineSplitter().convert(pubspec)) {
    if (RegExp(r'^\S').hasMatch(line)) {
      section = line.trimRight();
      pending = null;
      continue;
    }
    if (section != 'dependencies:' && section != 'dev_dependencies:') {
      continue;
    }
    final entry = RegExp(r'^  ([A-Za-z0-9_]+):\s*(.*)$').firstMatch(line);
    if (entry != null) {
      final value = entry[2]!.trim();
      installed[entry[1]!] = value.isEmpty ? 'any' : value;
      pending = value.isEmpty ? entry[1] : null;
    } else if (pending != null) {
      final source = RegExp(r'^    (path|git|hosted|sdk):').firstMatch(line);
      if (source != null) {
        installed[pending] = source[1]!;
        pending = null;
      }
    }
  }
  return installed;
}

/// [pubspec] with [package] in `dev_dependencies:` (created when missing),
/// unchanged when it is a dependency already.
String addDevDependency(String pubspec, String package, String constraint) {
  if (RegExp('^  $package:', multiLine: true).hasMatch(pubspec)) {
    return pubspec;
  }
  final section = RegExp(
    r'^dev_dependencies:[ \t]*\r?\n',
    multiLine: true,
  ).firstMatch(pubspec);
  if (section == null) {
    return '${pubspec.trimRight()}\n\ndev_dependencies:\n  $package: $constraint\n';
  }
  return pubspec.replaceRange(
    section.end,
    section.end,
    '  $package: $constraint\n',
  );
}

/// Where [pubspec] takes `daravel` from when it is a local checkout
/// (`path:` under `dependencies` or `dependency_overrides`), or `null`.
String? daravelPath(String pubspec) => RegExp(
  r'^  daravel:[ \t]*\r?\n    path:[ \t]*(\S+)',
  multiLine: true,
).firstMatch(pubspec)?[1];

/// [pubspec] with [package] as a path dependency (a sibling of the local
/// `daravel` checkout at [daravel]), unchanged when it is a dependency.
String addPathDependency(String pubspec, String package, String daravel) {
  if (RegExp('^  $package:', multiLine: true).hasMatch(pubspec)) {
    return pubspec;
  }
  final path = p.posix.join(
    p.posix.dirname(daravel.replaceAll(r'\', '/')),
    package,
  );
  final entry = '  $package:\n    path: $path\n';
  final section = RegExp(
    r'^dependencies:[ \t]*\r?\n',
    multiLine: true,
  ).firstMatch(pubspec);
  if (section == null) {
    return '${pubspec.trimRight()}\n\ndependencies:\n$entry';
  }
  return pubspec.replaceRange(section.end, section.end, entry);
}

/// [example] (`.env.example`) with a commented block for [manifest], once.
String addPackageEnv(String example, PackageManifest manifest) {
  final marker = '# ${manifest.title} (dartisan pub:add ${manifest.id})';
  if (manifest.env.isEmpty || example.contains(marker)) {
    return example;
  }
  final block = [marker, for (final line in manifest.env) '# $line'].join('\n');
  final base = example.isEmpty || example.endsWith('\n')
      ? example
      : '$example\n';
  return '$base\n$block\n';
}

/// Asks the person at the terminal; tests answer with a fake.
abstract interface class Prompter {
  /// Whether questions can be asked (a terminal, no `--yes`).
  bool get interactive;

  /// The indexes of [options] picked; empty when cancelled.
  Future<List<int>> pick(String title, List<String> options, {bool many});

  Future<bool> confirm(String question);
}

/// Questions on stdin: arrow keys and space in a terminal that allows raw
/// input, numbers typed otherwise (CI, Git Bash's mintty).
final class TerminalPrompter implements Prompter {
  const TerminalPrompter();

  @override
  bool get interactive => stdin.hasTerminal;

  @override
  Future<List<int>> pick(
    String title,
    List<String> options, {
    bool many = false,
  }) async {
    if (stdin.hasTerminal && stdout.hasTerminal && stdout.supportsAnsiEscapes) {
      return _arrows(title, options, many: many);
    }
    stdout.writeln(title);
    for (var i = 0; i < options.length; i++) {
      stdout.writeln('  ${i + 1}) ${options[i]}');
    }
    stdout.write(
      many
          ? 'Numbers to install, comma-separated (empty to cancel): '
          : 'Which one? [1-${options.length}, empty to cancel]: ',
    );
    return parsePicks(stdin.readLineSync() ?? '', options.length, many: many);
  }

  List<int> _arrows(String title, List<String> options, {required bool many}) {
    final state = SelectorState(options, many: many);
    final echo = stdin.echoMode;
    final line = stdin.lineMode;
    stdin
      ..echoMode = false
      ..lineMode = false;
    var drawn = 0;
    void draw() {
      if (drawn > 0) {
        stdout.write('\x1B[${drawn}A');
      }
      final lines = state.render(title);
      for (final text in lines) {
        stdout.write('\x1B[2K$text\n');
      }
      for (var i = lines.length; i < drawn; i++) {
        stdout.write('\x1B[2K\n');
      }
      drawn = lines.length > drawn ? lines.length : drawn;
    }

    try {
      draw();
      while (!state.done) {
        final byte = stdin.readByteSync();
        if (byte == 0x1B) {
          final next = stdin.readByteSync();
          if (next == 0x5B) {
            state.key(switch (stdin.readByteSync()) {
              0x41 => SelectorKey.up,
              0x42 => SelectorKey.down,
              _ => SelectorKey.none,
            });
          } else {
            state.key(SelectorKey.cancel);
          }
        } else if (byte == -1) {
          state.key(SelectorKey.cancel);
        } else {
          state.type(byte);
        }
        draw();
      }
    } finally {
      stdin
        ..lineMode = line
        ..echoMode = echo;
    }
    return state.result;
  }

  @override
  Future<bool> confirm(String question) async {
    stdout.write('$question [y/N] ');
    final answer = (stdin.readLineSync() ?? '').trim().toLowerCase();
    return answer == 'y' || answer == 'yes';
  }
}

/// `1,3` or `2` as zero-based indexes below [count]; empty for anything
/// unreadable or out of range.
List<int> parsePicks(String text, int count, {bool many = false}) {
  final picks = <int>[];
  for (final part in text.split(RegExp(r'[,\s]+'))) {
    if (part.isEmpty) {
      continue;
    }
    final n = int.tryParse(part);
    if (n == null || n < 1 || n > count) {
      return const [];
    }
    if (!picks.contains(n - 1)) {
      picks.add(n - 1);
    }
  }
  return many || picks.length <= 1 ? picks : const [];
}

/// Keys the selector understands.
enum SelectorKey { up, down, toggle, enter, cancel, backspace, none }

/// The interactive list of `pub:add`: a filter typed as text, a cursor,
/// and the ticked options. Pure, so it is tested without a terminal.
final class SelectorState {
  SelectorState(this.options, {this.many = true});

  final List<String> options;
  final bool many;
  String filter = '';
  int cursor = 0;
  final Set<int> ticked = {};
  bool done = false;
  bool cancelled = false;

  /// The indexes of [options] the filter keeps.
  List<int> get visible => [
    for (var i = 0; i < options.length; i++)
      if (options[i].toLowerCase().contains(filter.toLowerCase())) i,
  ];

  void key(SelectorKey key) {
    final shown = visible;
    switch (key) {
      case SelectorKey.up:
        cursor = shown.isEmpty ? 0 : (cursor - 1) % shown.length;
      case SelectorKey.down:
        cursor = shown.isEmpty ? 0 : (cursor + 1) % shown.length;
      case SelectorKey.toggle when shown.isNotEmpty:
        final index = shown[cursor.clamp(0, shown.length - 1)];
        if (!ticked.remove(index)) {
          if (!many) {
            ticked.clear();
          }
          ticked.add(index);
        }
      case SelectorKey.enter:
        if (ticked.isEmpty && shown.isNotEmpty) {
          ticked.add(shown[cursor.clamp(0, shown.length - 1)]);
        }
        done = true;
      case SelectorKey.cancel:
        cancelled = true;
        done = true;
      case SelectorKey.backspace:
        if (filter.isNotEmpty) {
          filter = filter.substring(0, filter.length - 1);
          cursor = 0;
        }
      case SelectorKey.toggle || SelectorKey.none:
        break;
    }
  }

  /// A typed byte: space ticks, enter confirms, `q` on an empty filter
  /// quits, printable characters filter.
  void type(int byte) {
    switch (byte) {
      case 0x20:
        key(SelectorKey.toggle);
      case 0x0A || 0x0D:
        key(SelectorKey.enter);
      case 0x08 || 0x7F:
        key(SelectorKey.backspace);
      case 0x03:
        key(SelectorKey.cancel);
      case 0x71 when filter.isEmpty:
        key(SelectorKey.cancel);
      default:
        if (byte >= 0x21 && byte < 0x7F) {
          filter += String.fromCharCode(byte);
          cursor = 0;
        }
    }
  }

  List<int> get result => cancelled ? const [] : (ticked.toList()..sort());

  List<String> render(String title) {
    final shown = visible;
    return [
      title,
      '  Filter: $filter',
      for (var i = 0; i < shown.length; i++)
        '${i == cursor ? '❯' : ' '} ${many ? (ticked.contains(shown[i]) ? '[x] ' : '[ ] ') : ''}${options[shown[i]]}',
      if (shown.isEmpty) '  (nothing matches)',
      '  ↑/↓ move · ${many ? 'space select · ' : ''}enter install · q quit',
    ];
  }
}

String _status(PackageManifest manifest, Map<String, String> installed) =>
    installed.containsKey(manifest.package) ? 'installed' : 'available';

Map<String, String> _projectPackages() {
  try {
    final root = ProjectPaths.locate().root;
    return installedPackages(
      File(p.join(root, 'pubspec.yaml')).readAsStringSync(),
    );
  } on StateError {
    return const {};
  }
}

String _table(List<List<String>> rows) {
  final widths = [
    for (var c = 0; c < rows.first.length; c++)
      rows.map((r) => r[c].length).reduce((a, b) => a > b ? a : b),
  ];
  return [
    for (final (i, row) in rows.indexed) ...[
      [for (var c = 0; c < row.length; c++) row[c].padRight(widths[c])]
          .join('  ')
          .trimRight(),
      if (i == 0) [for (final w in widths) '-' * w].join('  '),
    ],
  ].join('\n');
}

/// `pub:list`: the first-party packages and whether the project has them.
final class PubListCommand extends Command<int> {
  PubListCommand() {
    argParser.addFlag('json', negatable: false, help: 'Print JSON.');
  }

  @override
  String get name => 'pub:list';

  @override
  String get description => "List Daravel's first-party packages.";

  @override
  Future<int> run() async {
    final installed = _projectPackages();
    if (argResults!['json'] == true) {
      stdout.writeln(
        jsonEncode([
          for (final m in officialPackages)
            {
              'package': m.package,
              'id': m.id,
              'category': m.category,
              'description': m.description,
              'aliases': m.aliases,
              'dev': m.dev,
              'installed': installed[m.package],
            },
        ]),
      );
      return 0;
    }
    stdout
      ..writeln(
        _table([
          ['Package', 'Category', 'Description', 'Status'],
          for (final m in officialPackages)
            [
              m.package,
              m.category,
              m.description,
              installed.containsKey(m.package)
                  ? 'installed (${installed[m.package]})'
                  : 'available',
            ],
        ]),
      )
      ..writeln()
      ..writeln(
        'dartisan pub:search <words> to search, dartisan pub:add <name> to '
        'install (version ^$daravelVersion).',
      );
    return 0;
  }
}

/// Searches pub.dev: package names for [query], then each one's details.
typedef PubDevSearch =
    Future<List<({String name, String version, String description})>> Function(
      String query,
    );

Future<List<({String name, String version, String description})>> searchPubDev(
  String query,
) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 5);
  Future<Object?> get(Uri uri) async {
    final request = await client.getUrl(uri);
    final response = await request.close().timeout(const Duration(seconds: 8));
    if (response.statusCode != 200) {
      await response.drain<void>();
      return null;
    }
    return jsonDecode(await utf8.decodeStream(response));
  }

  try {
    final found = await get(Uri.https('pub.dev', '/api/search', {'q': query}));
    final names = [
      if (found case {'packages': final List<Object?> packages})
        for (final item in packages.take(8))
          if (item case {'package': final String name}) name,
    ];
    final details = await Future.wait([
      for (final name in names)
        get(Uri.https('pub.dev', '/api/packages/$name')),
    ]);
    return [
      for (final (i, detail) in details.indexed)
        if (detail case {
          'latest': {
            'version': final String version,
            'pubspec': final Map<String, Object?> pubspec,
          },
        })
          (
            name: names[i],
            version: version,
            description: '${pubspec['description'] ?? ''}'.trim(),
          ),
    ];
  } finally {
    client.close(force: true);
  }
}

/// `pub:search <words> [--online]`.
final class PubSearchCommand extends Command<int> {
  PubSearchCommand({PubDevSearch? pubDev}) : _pubDev = pubDev ?? searchPubDev {
    argParser.addFlag('online', negatable: false, help: 'Also search pub.dev.');
  }

  final PubDevSearch _pubDev;

  @override
  String get name => 'pub:search';

  @override
  String get description =>
      "Search Daravel's packages (and pub.dev with --online).";

  @override
  String get invocation => 'dartisan pub:search <words> [--online]';

  @override
  Future<int> run() async {
    final query = argResults!.rest.join(' ');
    if (query.trim().isEmpty) {
      usageException('Name what to search for.');
    }
    final installed = _projectPackages();
    final found = searchPackages(query);
    stdout.writeln('Daravel packages:');
    if (found.isEmpty) {
      stdout.writeln("  none match '$query'");
    }
    for (final m in found) {
      stdout
        ..writeln('  ${m.package} (${_status(m, installed)}): ${m.description}')
        ..writeln('    dartisan pub:add ${m.id}');
    }
    if (argResults!['online'] == true) {
      stdout.writeln('\npub.dev:');
      try {
        final results = await _pubDev(query);
        if (results.isEmpty) {
          stdout.writeln("  none match '$query'");
        }
        for (final r in results) {
          stdout
            ..writeln('  ${r.name} ${r.version}: ${r.description}')
            ..writeln('    dartisan pub:add ${r.name}');
        }
      } on Object catch (error) {
        stderr.writeln('  pub.dev could not be searched: $error');
      }
    } else if (found.isEmpty) {
      stdout.writeln('\nAdd --online to search pub.dev.');
    }
    return 0;
  }
}

/// `pub:add <name>... [--yes] [--no-get]` (also `install`): adds packages
/// and wires them into the project.
final class PubAddCommand extends Command<int> {
  PubAddCommand({Prompter? prompter, DartRunner? dart})
    : _prompter = prompter ?? const TerminalPrompter(),
      _dart = dart ?? runDart {
    argParser
      ..addFlag(
        'yes',
        abbr: 'y',
        negatable: false,
        help: 'Never ask: fail on an ambiguous name, add pub.dev packages.',
      )
      ..addFlag(
        'get',
        defaultsTo: true,
        help: 'Run `dart pub get` afterwards.',
      );
  }

  final Prompter _prompter;
  final DartRunner _dart;

  /// The bootstrap files this run changed: the only ones it formats.
  final Set<String> _touched = {};

  @override
  String get name => 'pub:add';

  @override
  List<String> get aliases => const ['install'];

  @override
  String get description =>
      'Add a Daravel package and wire it into the project.';

  @override
  String get invocation => 'dartisan pub:add [<name>...] [--yes] [--no-get]';

  bool get _ask => argResults!['yes'] != true && _prompter.interactive;

  @override
  Future<int> run() async {
    final root = ProjectPaths.locate().root;
    final names = argResults!.rest;
    final chosen = <PackageManifest>[];
    final community = <String>[];
    if (names.isEmpty) {
      if (!_ask) {
        usageException('Name the packages to add (dartisan pub:list).');
      }
      final installed = installedPackages(
        File(p.join(root, 'pubspec.yaml')).readAsStringSync(),
      );
      final available = [
        for (final m in officialPackages)
          if (!installed.containsKey(m.package)) m,
      ];
      if (available.isEmpty) {
        stdout.writeln('Every Daravel package is installed.');
        return 0;
      }
      final picks = await _prompter.pick('Daravel packages', [
        for (final m in available) '${m.package.padRight(20)} ${m.description}',
      ], many: true);
      if (picks.isEmpty) {
        stdout.writeln('Nothing installed.');
        return 0;
      }
      chosen.addAll(picks.map((i) => available[i]));
    }
    for (final name in names) {
      final matches = resolvePackages(name);
      if (matches.length == 1) {
        chosen.add(matches.single);
      } else if (matches.length > 1) {
        if (!_ask) {
          stderr.writeln(
            "'$name' names ${matches.map((m) => m.package).join(' and ')}; "
            'name one of them.',
          );
          return 64;
        }
        final picks = await _prompter.pick("'$name' matches:", [
          for (final m in matches) '${m.package} (${m.description})',
        ]);
        if (picks.isEmpty) {
          return 1;
        }
        chosen.add(matches[picks.single]);
      } else if (RegExp(r'^[a-z][a-z0-9_]*$').hasMatch(name) &&
          !name.startsWith('daravel_')) {
        community.add(name);
      } else {
        final suggestions = searchPackages(name).take(3);
        stderr.writeln(
          "No Daravel package is called '$name'."
          '${suggestions.isEmpty ? '' : ' Did you mean ${suggestions.map((m) => m.id).join(', ')}?'}',
        );
        return 64;
      }
    }
    var changed = false;
    final next = <String>{};
    for (final manifest in {...chosen}) {
      final result = await _install(root, manifest);
      if (result.exit != 0) {
        return result.exit;
      }
      changed = changed || result.changed;
      next.addAll(result.next);
    }
    for (final package in community) {
      // Not a Daravel package: installed from pub.dev only when confirmed.
      if (argResults!['yes'] != true &&
          !(_prompter.interactive &&
              await _prompter.confirm(
                "'$package' is not a Daravel package. Add it from pub.dev?",
              ))) {
        stdout.writeln('Skipped $package (pass --yes to add it).');
        continue;
      }
      final code = await _dart(['pub', 'add', package], workingDirectory: root);
      if (code != 0) {
        return code;
      }
      stdout.writeln('Added $package from pub.dev.');
    }
    if (changed && argResults!['get'] == true) {
      final code = await _dart(['pub', 'get'], workingDirectory: root);
      if (code != 0) {
        return code;
      }
      if (_touched.isNotEmpty) {
        await _dart(['format', ..._touched], workingDirectory: root);
      }
    }
    if (next.isNotEmpty) {
      stdout.writeln('\nNext:');
      for (final step in next) {
        stdout.writeln('  - $step');
      }
    }
    return 0;
  }

  Future<({int exit, bool changed, List<String> next})> _install(
    String root,
    PackageManifest manifest,
  ) async {
    final delegate = manifest.delegate;
    if (delegate != null) {
      final code =
          await runner!.run([
            ...delegate,
            if (argResults!['get'] != true) '--no-get',
          ]) ??
          0;
      return (exit: code, changed: false, next: const <String>[]);
    }
    final changes = <String>[];
    void update(String relative, String Function(String) edit, String what) {
      final file = File(p.join(root, relative));
      final before = file.existsSync() ? file.readAsStringSync() : '';
      final after = edit(before);
      if (after != before) {
        file
          ..parent.createSync(recursive: true)
          ..writeAsStringSync(after);
        changes.add('$relative ($what)');
      }
    }

    final constraint = '^$daravelVersion';
    final pubspecText = File(p.join(root, 'pubspec.yaml')).readAsStringSync();
    // A project on a local checkout takes the package from it too.
    final local = daravelPath(pubspecText);
    update(
      'pubspec.yaml',
      (text) => local != null
          ? addPathDependency(text, manifest.package, local)
          : manifest.dev
          ? addDevDependency(text, manifest.package, constraint)
          : addDependency(text, manifest.package, constraint),
      local != null
          ? '${manifest.package} from the local checkout'
          : '${manifest.package}: $constraint',
    );
    if (manifest.registration.isNotEmpty) {
      final bootstrap = File(p.join(root, 'bootstrap', 'app.dart'));
      if (bootstrap.existsSync()) {
        final driver = DriverPackage(
          package: manifest.package,
          title: manifest.title,
          connection: manifest.id,
          note: manifest.title,
          registration: manifest.registration,
          env: manifest.env,
        );
        final source = bootstrap.readAsStringSync();
        final registered = registerDriver(source, driver);
        if (registered == null) {
          stderr.writeln(
            'bootstrap/app.dart has no Application.configure(...); add '
            '${manifest.registration.join(' ')} and ${manifest.import} by hand.',
          );
        } else if (registered != source) {
          bootstrap.writeAsStringSync(registered);
          _touched.add('bootstrap/app.dart');
          changes.add(
            'bootstrap/app.dart (${manifest.registration.join(' ')})',
          );
        }
      }
    }
    for (final migration in manifest.migrations) {
      _registry(
        root,
        'migrations.dart',
        manifest.import,
        'const $migration(),',
        changes,
      );
    }
    if (manifest.commands case final commands?) {
      _registry(
        root,
        'commands.dart',
        "import 'package:${manifest.package}/commands.dart';",
        '...$commands,',
        changes,
      );
    }
    update(
      '.env.example',
      (text) => addPackageEnv(text, manifest),
      '${manifest.title} keys',
    );
    if (changes.isEmpty) {
      stdout.writeln('${manifest.package} is already installed.');
      return (exit: 0, changed: false, next: const <String>[]);
    }
    stdout.writeln('Added ${manifest.package}:');
    for (final change in changes) {
      stdout.writeln('  updated $change');
    }
    return (exit: 0, changed: true, next: manifest.next);
  }

  void _registry(
    String root,
    String file,
    String importLine,
    String entryLine,
    List<String> changes,
  ) {
    final registry = File(p.join(root, 'bootstrap', file));
    if (!registry.existsSync()) {
      stderr.writeln('bootstrap/$file is missing; add $entryLine by hand.');
      return;
    }
    try {
      final patched = RegistryPatcher.patch(
        registry.readAsStringSync(),
        importLine: importLine,
        entryLine: entryLine,
      );
      if (patched != null) {
        registry.writeAsStringSync(patched);
        _touched.add('bootstrap/$file');
        changes.add('bootstrap/$file ($entryLine)');
      }
    } on StateError catch (error) {
      stderr.writeln(
        'bootstrap/$file: ${error.message} Add $entryLine by hand.',
      );
    }
  }
}
