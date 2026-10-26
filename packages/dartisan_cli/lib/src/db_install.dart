import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:daravel/daravel.dart' show daravelVersion;
import 'package:path/path.dart' as p;

import 'generator.dart';

/// A database driver package `db:install` can add.
final class DriverPackage {
  const DriverPackage({
    required this.package,
    required this.title,
    required this.connection,
    required this.registration,
    required this.env,
  });

  /// The pub package (`daravel_postgres`).
  final String package;
  final String title;

  /// The `DB_CONNECTION` value (`pgsql`).
  final String connection;

  /// The calls added to the application builder, one per line.
  final List<String> registration;

  /// Example `.env` lines.
  final List<String> env;

  String get import => "import 'package:$package/$package.dart';";
}

/// The drivers by `db:install` name (aliases included).
const Map<String, DriverPackage> driverPackages = {
  'sqlite': _sqlite,
  'pgsql': _postgres,
  'postgres': _postgres,
  'postgresql': _postgres,
  'mysql': _mysql,
  'mariadb': _mariadb,
};

const DriverPackage _sqlite = DriverPackage(
  package: 'daravel_sqlite',
  title: 'SQLite',
  connection: 'sqlite',
  registration: ['.withSqlite()'],
  env: ['DB_CONNECTION=sqlite', 'DB_DATABASE=database/database.sqlite'],
);

const DriverPackage _postgres = DriverPackage(
  package: 'daravel_postgres',
  title: 'PostgreSQL',
  connection: 'pgsql',
  registration: ['.withPostgres()'],
  env: [
    'DB_CONNECTION=pgsql',
    'DB_HOST=127.0.0.1',
    'DB_PORT=5432',
    'DB_DATABASE=app',
    'DB_USERNAME=app',
    'DB_PASSWORD=',
    'DB_SSLMODE=disable',
  ],
);

const DriverPackage _mysql = DriverPackage(
  package: 'daravel_mysql',
  title: 'MySQL',
  connection: 'mysql',
  registration: [
    ".withDatabaseDriver('mysql', MySqlDriver.fromConfig)",
    ".withDatabaseDriver('mariadb', MySqlDriver.fromConfig)",
  ],
  env: [
    'DB_CONNECTION=mysql',
    'DB_HOST=127.0.0.1',
    'DB_PORT=3306',
    'DB_DATABASE=app',
    'DB_USERNAME=app',
    'DB_PASSWORD=',
  ],
);

const DriverPackage _mariadb = DriverPackage(
  package: 'daravel_mysql',
  title: 'MariaDB',
  connection: 'mariadb',
  registration: [
    ".withDatabaseDriver('mysql', MySqlDriver.fromConfig)",
    ".withDatabaseDriver('mariadb', MySqlDriver.fromConfig)",
  ],
  env: [
    'DB_CONNECTION=mariadb',
    'DB_HOST=127.0.0.1',
    'DB_PORT=3306',
    'DB_DATABASE=app',
    'DB_USERNAME=app',
    'DB_PASSWORD=',
  ],
);

/// [pubspec] with `package: constraint` under `dependencies:`, or
/// unchanged when the package is already a dependency.
String addDependency(String pubspec, String package, String constraint) {
  if (RegExp('^  $package:', multiLine: true).hasMatch(pubspec)) {
    return pubspec;
  }
  final section = RegExp(
    r'^dependencies:[ \t]*\r?\n',
    multiLine: true,
  ).firstMatch(pubspec);
  if (section == null) {
    return '${pubspec.trimRight()}\n\ndependencies:\n  $package: $constraint\n';
  }
  // After the last entry of the section, keeping its order.
  var end = section.end;
  for (final line in RegExp(
    r'^  .*\r?\n',
    multiLine: true,
  ).allMatches(pubspec, section.end)) {
    if (line.start != end) {
      break;
    }
    end = line.end;
  }
  return pubspec.replaceRange(end, end, '  $package: $constraint\n');
}

/// [source] (`bootstrap/app.dart`) with the import and the builder calls of
/// [driver], or `null` when it has no `Application.configure(...)` to add
/// them to. Calls and imports already present are not repeated.
String? registerDriver(String source, DriverPackage driver) {
  var result = source;
  final missing = [
    for (final call in driver.registration)
      if (!result.contains(call)) call,
  ];
  if (missing.isNotEmpty) {
    final start = result.indexOf('Application.configure(');
    if (start < 0) {
      return null;
    }
    final close = _closingParen(result, start + 'Application.configure'.length);
    if (close < 0) {
      return null;
    }
    // Indent like the next builder call, or eight spaces.
    final next = RegExp(r'\n([ \t]+)\.').firstMatch(result.substring(close));
    final indent = next?[1] ?? '        ';
    final lines = [
      '$indent// DB_CONNECTION=${driver.connection} (package:${driver.package}).',
      for (final call in missing) '$indent$call',
    ];
    result = result.replaceRange(close + 1, close + 1, '\n${lines.join('\n')}');
  }
  if (!result.contains(driver.import)) {
    final imports = RegExp(
      r"^import 'package:[^']+';\r?\n",
      multiLine: true,
    ).allMatches(result).toList();
    final at = imports.isEmpty ? 0 : imports.last.end;
    result = result.replaceRange(at, at, '${driver.import}\n');
  }
  return result;
}

/// The index of the `)` closing the `(` at [open], skipping strings.
int _closingParen(String source, int open) {
  var depth = 0;
  String? quote;
  for (var i = open; i < source.length; i++) {
    final char = source[i];
    if (quote != null) {
      if (char == r'\') {
        i++;
      } else if (char == quote) {
        quote = null;
      }
      continue;
    }
    if (char == "'" || char == '"') {
      quote = char;
    } else if (char == '(') {
      depth++;
    } else if (char == ')') {
      depth--;
      if (depth == 0) {
        return i;
      }
    }
  }
  return -1;
}

/// [example] (`.env.example`) with a commented block for [driver], once.
String addEnvExample(String example, DriverPackage driver) {
  final marker = '# ${driver.title} (dartisan db:install ${driver.connection})';
  if (example.contains(marker)) {
    return example;
  }
  final block = [marker, for (final line in driver.env) '# $line'].join('\n');
  final base = example.isEmpty || example.endsWith('\n')
      ? example
      : '$example\n';
  return '$base\n$block\n';
}

/// `db:install <driver>`: adds a database driver package to the project,
/// registers it in `bootstrap/app.dart` and documents its `.env` keys.
final class DbInstallCommand extends Command<int> {
  DbInstallCommand() {
    argParser.addFlag(
      'get',
      defaultsTo: true,
      help: 'Run `dart pub get` afterwards.',
    );
  }

  @override
  String get name => 'db:install';

  @override
  String get description =>
      'Add a database driver package (${driverPackages.keys.join(', ')}).';

  @override
  String get invocation => 'dartisan db:install <driver>';

  @override
  Future<int> run() async {
    final args = argResults!.rest;
    final driver = args.length == 1 ? driverPackages[args.single] : null;
    if (driver == null) {
      usageException('Name one driver: ${driverPackages.keys.join(', ')}.');
    }
    final root = ProjectPaths.locate().root;
    final changed = <String>[];

    final pubspec = File(p.join(root, 'pubspec.yaml'));
    final pubspecText = pubspec.readAsStringSync();
    final withDependency = addDependency(
      pubspecText,
      driver.package,
      '^$daravelVersion',
    );
    if (withDependency != pubspecText) {
      pubspec.writeAsStringSync(withDependency);
      changed.add('pubspec.yaml (${driver.package}: ^$daravelVersion)');
    }

    final bootstrap = File(p.join(root, 'bootstrap', 'app.dart'));
    if (bootstrap.existsSync()) {
      final source = bootstrap.readAsStringSync();
      final registered = registerDriver(source, driver);
      if (registered == null) {
        stderr.writeln(
          'bootstrap/app.dart has no Application.configure(...); add '
          '${driver.registration.join(' ')} and ${driver.import} by hand.',
        );
      } else if (registered != source) {
        bootstrap.writeAsStringSync(registered);
        changed.add('bootstrap/app.dart (${driver.registration.join(' ')})');
      }
    }

    final example = File(p.join(root, '.env.example'));
    final exampleText = example.existsSync() ? example.readAsStringSync() : '';
    final withEnv = addEnvExample(exampleText, driver);
    if (withEnv != exampleText) {
      example.writeAsStringSync(withEnv);
      changed.add('.env.example (${driver.title} keys)');
    }

    if (changed.isEmpty) {
      stdout.writeln('${driver.title} is already installed.');
      return 0;
    }
    for (final line in changed) {
      stdout.writeln('Updated $line');
    }
    if (argResults!['get'] == true) {
      final dart = Platform.resolvedExecutable;
      final get = await Process.run(dart, [
        'pub',
        'get',
      ], workingDirectory: root);
      if (get.exitCode != 0) {
        stderr
          ..write(get.stdout)
          ..write(get.stderr);
        return get.exitCode;
      }
      await Process.run(dart, [
        'format',
        p.join(root, 'bootstrap', 'app.dart'),
      ]);
    }
    stdout.writeln(
      'Set DB_CONNECTION=${driver.connection} and the DB_* keys in .env, then '
      'run `dartisan migrate`. To copy existing data across, use '
      '`dartisan db:transfer --from=<connection> --to=<connection>`.',
    );
    return 0;
  }
}
