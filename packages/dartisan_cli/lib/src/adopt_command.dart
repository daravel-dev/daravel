import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:daravel/daravel.dart';
import 'package:path/path.dart' as p;

import 'generator.dart';
import 'project_commands.dart';

/// Settings copied from the Laravel `.env` so both applications share the
/// database, the encryption key and the password hashing parameters.
const List<String> adoptedEnvKeys = [
  'APP_KEY',
  'APP_PREVIOUS_KEYS',
  'APP_CIPHER',
  'DB_CONNECTION',
  'DB_HOST',
  'DB_PORT',
  'DB_DATABASE',
  'DB_USERNAME',
  'DB_PASSWORD',
  'DB_SSLMODE',
  'HASH_DRIVER',
  'BCRYPT_ROUNDS',
  'ARGON_MEMORY',
  'ARGON_THREADS',
  'ARGON_TIME',
];

/// Tables a Laravel application shares with Daravel (Laravel coexistence
/// guide); missing ones are reported, not created.
const List<String> sharedTables = [
  'migrations',
  'users',
  'personal_access_tokens',
  'cache',
  'jobs',
  'failed_jobs',
];

/// `adopt <laravel-path> [--check]` — prepares this project to run next to
/// an existing Laravel application on the same database: copies the shared
/// settings from its `.env` and checks that coexistence will work. The
/// Laravel project is only read, never changed.
final class AdoptCommand extends Command<int> {
  AdoptCommand({this.root}) {
    argParser
      ..addFlag(
        'check',
        negatable: false,
        help: 'Only report; do not change this project\'s .env.',
      )
      ..addFlag(
        'skip-database',
        negatable: false,
        help: 'Do not connect to the database.',
      );
  }

  /// Project root; located from the working directory when `null`.
  final String? root;

  @override
  String get name => 'adopt';

  @override
  String get description =>
      'Share the database and keys of an existing Laravel application.';

  @override
  String get invocation => 'dartisan adopt <laravel-path> [--check]';

  @override
  Future<int> run() async {
    final args = argResults!;
    if (args.rest.length != 1) {
      usageException('Pass the path of the Laravel project.');
    }
    final laravel = p.normalize(p.absolute(args.rest.single));
    final report = _Report();

    final version = laravelVersion(laravel);
    if (!File(p.join(laravel, 'artisan')).existsSync() || version == null) {
      stderr.writeln(
        'No Laravel project at $laravel (expected artisan and '
        'laravel/framework in composer.lock).',
      );
      return 1;
    }
    final major = int.tryParse(version.split('.').first) ?? 0;
    if (major == 11 || major == 12) {
      report.ok('Laravel $version');
    } else {
      report.warn(
        'Laravel $version',
        'The conformance suite pins Laravel 12 (11 shares its formats). '
            'Check the coexistence guide for changes in this version.',
      );
    }

    final envFile = File(p.join(laravel, '.env'));
    if (!envFile.existsSync()) {
      stderr.writeln('$laravel has no .env file.');
      return 1;
    }
    final source = Env.parse(envFile.readAsStringSync());
    final adopted = <String, String>{
      for (final key in adoptedEnvKeys)
        if ((source[key] ?? '').isNotEmpty) key: source[key]!,
    };
    final driver = adopted['DB_CONNECTION'] ?? 'sqlite';
    if (driver == 'sqlite') {
      final database = adopted['DB_DATABASE'];
      // Laravel's default; relative paths resolve against its root.
      adopted['DB_DATABASE'] = database == null
          ? p.join(laravel, 'database', 'database.sqlite')
          : (p.isAbsolute(database) || database == ':memory:'
                ? database
                : p.normalize(p.join(laravel, database)));
    }
    // Keep cache values apart: Laravel stores PHP-serialized values.
    final appName = source['APP_NAME'] ?? 'laravel';
    adopted['CACHE_PREFIX'] = 'daravel_cache_';
    final laravelPrefix =
        source['CACHE_PREFIX'] ??
        '${appName.toLowerCase().replaceAll(RegExp('[^a-z0-9]+'), '_')}_cache_';
    if (laravelPrefix == 'daravel_cache_') {
      report.warn(
        'Laravel already uses CACHE_PREFIX=daravel_cache_',
        'Pick another prefix for one of the applications.',
      );
    }

    _checkKey(adopted['APP_KEY'], report);
    _checkCipherAndHash(adopted, report);
    if (source['DB_URL'] case final url? when url.isNotEmpty) {
      report.warn(
        'Laravel uses DB_URL',
        'Daravel reads DB_HOST, DB_PORT, DB_DATABASE, DB_USERNAME and '
            'DB_PASSWORD; copy the parts of the URL into them.',
      );
    }
    final supported = driver == 'sqlite' || driver == 'pgsql';
    if (supported) {
      report.ok('Database driver $driver');
    } else {
      report.fail(
        'Database driver $driver is not supported yet',
        'Daravel runs on SQLite and PostgreSQL; the MySQL/MariaDB driver is '
            'planned.',
      );
    }
    if (supported && !(args['skip-database'] as bool)) {
      await _checkDatabase(driver, adopted, report);
    }
    report
      ..note(
        'Queues: give Daravel its own queue names '
        "(Queue.dispatch(job).onQueue('daravel'), queue:work --queue=daravel).",
      )
      ..note(
        'Schema: let one side own migrations (see migrating-from-laravel).',
      );

    final projectRoot = root ?? ProjectPaths.locate().root;
    final target = File(p.join(projectRoot, '.env'));
    if (args['check'] as bool) {
      report.note('--check: .env not changed.');
    } else if (report.failed) {
      report.note('.env not changed because of the failures above.');
    } else {
      var content = target.existsSync() ? target.readAsStringSync() : '';
      if (content.isNotEmpty) {
        File('${target.path}.before-adopt').writeAsStringSync(content);
      }
      for (final MapEntry(:key, :value) in adopted.entries) {
        content = setEnvValue(content, key, _quote(value));
      }
      target.writeAsStringSync(content);
      report.ok(
        'Wrote ${adopted.length} setting(s) to .env'
        '${content.isEmpty ? '' : ' (previous file: .env.before-adopt)'}',
      );
    }
    report.print();
    return report.failed ? 1 : 0;
  }

  void _checkKey(String? key, _Report report) {
    if (key == null) {
      report.fail('APP_KEY is not set in the Laravel .env');
      return;
    }
    try {
      Encrypter.fromAppKey(key);
      report.ok('APP_KEY is a valid AES-256 key (shared with Laravel)');
    } on EncryptException catch (error) {
      report.fail('APP_KEY cannot be used', error.message);
    }
  }

  void _checkCipherAndHash(Map<String, String> env, _Report report) {
    final cipher = env['APP_CIPHER'] ?? 'AES-256-CBC';
    try {
      EncryptionCipher.parse(cipher);
      report.ok('Cipher $cipher');
    } on Object {
      report.fail('Cipher $cipher is not supported', 'Use AES-256-CBC or GCM.');
    }
    final hash = env['HASH_DRIVER'] ?? 'bcrypt';
    if (hash == 'bcrypt' || hash == 'argon2id') {
      report.ok('Password hashing $hash');
    } else {
      report.fail(
        'Password hashing $hash is not shared',
        'Daravel verifies bcrypt and argon2id hashes.',
      );
    }
  }

  Future<void> _checkDatabase(
    String driver,
    Map<String, String> env,
    _Report report,
  ) async {
    final manager = DatabaseManager(
      DatabaseConfig(
        defaultConnection: driver,
        connections: {
          driver: ConnectionConfig(
            driver: driver,
            database: env['DB_DATABASE'] ?? 'laravel',
            host: env['DB_HOST'],
            port: int.tryParse(env['DB_PORT'] ?? ''),
            username: env['DB_USERNAME'],
            password: env['DB_PASSWORD'],
            options: {'sslmode': env['DB_SSLMODE'] ?? 'disable', 'pool': 1},
          ),
        },
      ),
    );
    try {
      if (driver == 'sqlite' && !File(env['DB_DATABASE']!).existsSync()) {
        report.fail('SQLite database not found', env['DB_DATABASE']);
        return;
      }
      final schema = SchemaBuilder(await manager.executor());
      final missing = <String>[
        for (final table in sharedTables)
          if (!await schema.hasTable(table)) table,
      ];
      if (missing.isEmpty) {
        report.ok('Database reachable; shared tables present');
      } else {
        report.warn(
          'Database reachable; missing: ${missing.join(', ')}',
          'Create them from Laravel (php artisan migrate, install:api, '
              'queue:table, cache:table) so both sides use one schema.',
        );
      }
    } catch (error) {
      report.fail('Database unreachable', '$error');
    } finally {
      await manager.closeAll();
    }
  }

  /// Quotes [value] for a `.env` file so it reads back unchanged: single
  /// quotes when possible (no `$` expansion), double quotes otherwise.
  static String _quote(String value) {
    if (!RegExp(r'''[\s#"'\\$]''').hasMatch(value)) {
      return value;
    }
    if (!value.contains("'") && !value.contains('\n')) {
      return "'$value'";
    }
    return '"${value.replaceAll(r'\', r'\\').replaceAll('"', r'\"').replaceAll('\n', r'\n')}"';
  }
}

/// The `laravel/framework` version of the project at [root], from
/// `composer.lock` (or `null` when it is not a Laravel project).
String? laravelVersion(String root) {
  final lock = File(p.join(root, 'composer.lock'));
  if (!lock.existsSync()) {
    return null;
  }
  final match = RegExp(
    r'"name":\s*"laravel/framework",\s*"version":\s*"v?([^"]+)"',
  ).firstMatch(lock.readAsStringSync());
  return match?.group(1);
}

final class _Report {
  final List<DoctorCheck> _checks = [];
  final List<String> _notes = [];

  bool get failed => _checks.any((c) => c.status == CheckStatus.error);

  void ok(String title) => _checks.add(DoctorCheck(CheckStatus.ok, title));

  void warn(String title, [String? detail]) =>
      _checks.add(DoctorCheck(CheckStatus.warning, title, detail));

  void fail(String title, [String? detail]) =>
      _checks.add(DoctorCheck(CheckStatus.error, title, detail));

  void note(String text) => _notes.add(text);

  void print() {
    for (final check in _checks) {
      stdout.writeln(
        '${check.symbol} ${check.title}'
        '${check.detail == null ? '' : '\n         ${check.detail}'}',
      );
    }
    for (final note in _notes) {
      stdout.writeln('  - $note');
    }
  }
}
