import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:daravel/daravel.dart';
import 'package:daravel_lints/daravel_lints.dart';
import 'package:path/path.dart' as p;

import '../dartisan_cli.dart';

/// Sets `KEY=value` in a `.env` file body (replacing or appending).
String setEnvValue(String content, String key, String value) {
  final pattern = RegExp('^${RegExp.escape(key)}=.*\$', multiLine: true);
  if (pattern.hasMatch(content)) {
    return content.replaceFirst(pattern, '$key=$value');
  }
  final separator = content.isEmpty || content.endsWith('\n') ? '' : '\n';
  return '$content$separator$key=$value\n';
}

/// Reads `KEY=value` pairs from a `.env` body (no interpolation).
Map<String, String> parseEnvKeys(String content) => <String, String>{
  for (final line in const LineSplitter().convert(content))
    if (RegExp(r'^\s*[A-Za-z_][A-Za-z0-9_]*\s*=').hasMatch(line))
      line.substring(0, line.indexOf('=')).trim(): line
          .substring(line.indexOf('=') + 1)
          .trim(),
};

/// `key:generate [--show] [--force]` — writes a fresh `APP_KEY` to `.env`.
final class KeyGenerateCommand extends Command<int> {
  KeyGenerateCommand() {
    argParser
      ..addFlag('show', negatable: false, help: 'Print the key only.')
      ..addFlag(
        'force',
        negatable: false,
        help:
            'Replace an existing key (invalidates encrypted data, tokens '
            'signed with it and signed URLs).',
      );
  }

  @override
  String get name => 'key:generate';

  @override
  String get description => 'Set the application key.';

  @override
  Future<int> run() async {
    final key = Encrypter.generateKey();
    if (argResults!['show'] as bool) {
      stdout.writeln(key);
      return 0;
    }
    final root = ProjectPaths.locate().root;
    final env = File(p.join(root, '.env'));
    if (!env.existsSync()) {
      final example = File(p.join(root, '.env.example'));
      env.writeAsStringSync(
        example.existsSync() ? example.readAsStringSync() : '',
      );
      stdout.writeln('Created .env from .env.example.');
    }
    final content = env.readAsStringSync();
    final current = parseEnvKeys(content)['APP_KEY'] ?? '';
    if (current.isNotEmpty && !(argResults!['force'] as bool)) {
      stderr.writeln(
        'APP_KEY is already set. Rotating it invalidates encrypted values, '
        'JWTs and signed URLs; re-run with --force to replace it.',
      );
      return 1;
    }
    env.writeAsStringSync(setEnvValue(content, 'APP_KEY', key));
    stdout.writeln('Application key set successfully.');
    return 0;
  }
}

/// Oldest Dart SDK Daravel supports (keep in sync with every pubspec).
const (int, int) minimumDartSdk = (3, 13);

/// One `doctor` finding.
///
/// [notice] is advice about tuning (worker count, log level, SQLite under
/// several isolates): printed, but it never fails `doctor`, not even with
/// `--production`, which deployments use as a gate.
enum CheckStatus { ok, notice, warning, error }

final class DoctorCheck {
  const DoctorCheck(this.status, this.title, [this.detail]);

  final CheckStatus status;
  final String title;
  final String? detail;

  String get symbol => switch (status) {
    .ok => '[ok]  ',
    .notice => '[note]',
    .warning => '[warn]',
    .error => '[FAIL]',
  };
}

/// `doctor [--production]` — environment and configuration pre-flight.
final class DoctorCommand extends DaravelCommand {
  DoctorCommand(super.createApp) {
    argParser.addFlag(
      'production',
      negatable: false,
      help: 'Treat warnings as failures (container entrypoint pre-flight).',
    );
  }

  @override
  String get name => 'doctor';

  @override
  String get description => 'Diagnose the environment and configuration.';

  @override
  Future<int> run() async {
    final strict = argResults!['production'] as bool;
    final checks = await diagnose(production: strict);
    for (final check in checks) {
      stdout.writeln(
        '${check.symbol} ${check.title}'
        '${check.detail == null ? '' : '\n         ${check.detail}'}',
      );
    }
    final failed = checks.where(
      (c) => c.status == .error || (strict && c.status == .warning),
    );
    stdout.writeln(
      failed.isEmpty
          ? '\nAll checks passed.'
          : '\n${failed.length} check(s) need attention.',
    );
    return failed.isEmpty ? 0 : 1;
  }

  /// Runs every check (also used by tests). With [production] (the
  /// `--production` flag) the application must run with
  /// `APP_ENV=production`, since the checks that only apply there would
  /// otherwise be skipped and the gate would pass on a configuration that
  /// was never the deployed one.
  Future<List<DoctorCheck>> diagnose({bool production = false}) async {
    final checks = <DoctorCheck>[];
    final version = RegExp(r'^(\d+)\.(\d+)').firstMatch(Platform.version);
    final major = int.parse(version?.group(1) ?? '0');
    final minor = int.parse(version?.group(2) ?? '0');
    checks.add(
      major > minimumDartSdk.$1 ||
              (major == minimumDartSdk.$1 && minor >= minimumDartSdk.$2)
          ? DoctorCheck(
              CheckStatus.ok,
              'Dart SDK ${Platform.version.split(' ').first}',
            )
          : DoctorCheck(
              CheckStatus.error,
              'Dart SDK ${Platform.version.split(' ').first}',
              'Daravel needs Dart ^${minimumDartSdk.$1}.${minimumDartSdk.$2}.',
            ),
    );

    ProjectPaths? paths;
    try {
      paths = ProjectPaths.locate();
      checks.add(
        DoctorCheck(
          CheckStatus.ok,
          'Project ${paths.packageName} at ${paths.root}',
        ),
      );
    } on StateError catch (e) {
      checks.add(DoctorCheck(CheckStatus.error, 'Project root', e.message));
    }
    if (paths != null) {
      final env = File(p.join(paths.root, '.env'));
      final example = File(p.join(paths.root, '.env.example'));
      final encrypted = File(p.join(paths.root, '.env.encrypted'));
      final hasKey = EnvironmentEncrypter.keyVariables.any(
        (name) => (Platform.environment[name] ?? '').isNotEmpty,
      );
      if (encrypted.existsSync()) {
        checks.add(
          hasKey
              ? const DoctorCheck(
                  CheckStatus.ok,
                  '.env.encrypted is decrypted in memory at boot',
                )
              : const DoctorCheck(
                  CheckStatus.warning,
                  '.env.encrypted is present but no key is set',
                  'Set DARAVEL_ENV_ENCRYPTION_KEY (or '
                      'LARAVEL_ENV_ENCRYPTION_KEY) to load it.',
                ),
        );
      }
      if (!env.existsSync() && encrypted.existsSync()) {
        // Configuration comes from the encrypted file.
      } else if (!env.existsSync()) {
        // A container built by `build --docker` has no .env (its
        // .dockerignore keeps it out) and is configured by the OS
        // environment: a note, so the gate the image runs still passes.
        final fromOs = (Platform.environment['APP_ENV'] ?? '').isNotEmpty;
        checks.add(
          DoctorCheck(
            fromOs ? CheckStatus.notice : CheckStatus.warning,
            fromOs
                ? '.env is missing; configured by the OS environment'
                : '.env is missing',
            'Copy .env.example to .env (OS environment variables still apply).',
          ),
        );
      } else if (example.existsSync()) {
        final missing = parseEnvKeys(example.readAsStringSync()).keys.toSet()
          ..removeAll(parseEnvKeys(env.readAsStringSync()).keys);
        checks.add(
          missing.isEmpty
              ? const DoctorCheck(
                  CheckStatus.ok,
                  '.env has every key from .env.example',
                )
              : DoctorCheck(
                  CheckStatus.warning,
                  '.env lacks ${missing.length} key(s) from .env.example',
                  missing.join(', '),
                ),
        );
      }
    }

    final app = createApp();
    try {
      await app.boot();
    } catch (error) {
      checks.add(DoctorCheck(CheckStatus.error, 'Application boot', '$error'));
      return checks;
    }
    try {
      await app.run(() async {
        checks.addAll(await _appChecks(app, paths, production: production));
      });
    } finally {
      await app.shutdown();
    }
    return checks;
  }

  Future<List<DoctorCheck>> _appChecks(
    Application app,
    ProjectPaths? paths, {
    required bool production,
  }) async {
    final checks = <DoctorCheck>[];
    final appConfig = app.config.section<AppConfig>();
    final env = app.env;
    checks.add(
      DoctorCheck(
        CheckStatus.ok,
        'Application boots (APP_ENV=${appConfig.env})',
      ),
    );
    if (production && !appConfig.isProduction) {
      checks.add(
        DoctorCheck(
          CheckStatus.error,
          'doctor --production with APP_ENV=${appConfig.env}',
          'Set APP_ENV=production: the checks that only apply there '
              '(debug mode, the application key, /metrics, the queue, '
              'hashing) were skipped, so this run proves nothing about the '
              'deployed configuration.',
        ),
      );
    }
    checks.addAll(_productionChecks(app, appConfig, paths));

    for (final issue in ConfigValidator(
      extraChecks: const [DatabaseConfig.check],
    ).validate(env, app.config)) {
      checks.add(
        DoctorCheck(
          issue.isError ? CheckStatus.error : CheckStatus.warning,
          'Config: ${issue.message}',
        ),
      );
    }
    final key = env.maybeString('APP_KEY');
    if (key != null && key.isNotEmpty) {
      try {
        Encrypter.fromAppKey(key);
        checks.add(
          const DoctorCheck(CheckStatus.ok, 'APP_KEY is a valid 32-byte key'),
        );
      } on DaravelException catch (e) {
        checks.add(DoctorCheck(CheckStatus.error, 'APP_KEY', e.message));
      }
    }

    final stopwatch = Stopwatch()..start();
    final db = app.config.section<DatabaseConfig>();
    var reachable = false;
    try {
      await DB.manager.select('SELECT 1');
      reachable = true;
      checks.add(
        DoctorCheck(
          CheckStatus.ok,
          'Database [${db.defaultConnection}] reachable '
          '(${stopwatch.elapsedMilliseconds} ms)',
        ),
      );
    } catch (error) {
      checks.add(
        DoctorCheck(
          CheckStatus.error,
          'Database [${db.defaultConnection}] unreachable',
          '$error',
        ),
      );
    }
    final serve = ServeOptions.fromEnv(env);
    final connection = db.connections[db.defaultConnection];
    // The pool the driver really opens: DB_POOL_SIZE, or `pool=` in DB_URL.
    final pool =
        connection?.options['pool'] as int? ?? env.integer('DB_POOL_SIZE', 10);
    final appZone = env.string('APP_TIMEZONE', 'UTC');
    if (appZone.toUpperCase() != 'UTC' &&
        env.string('SCHEDULE_TIMEZONE', '').isEmpty &&
        App.make<Schedule>().tasks.isNotEmpty) {
      checks.add(
        DoctorCheck(
          CheckStatus.warning,
          'Scheduled tasks run in UTC, not APP_TIMEZONE ($appZone)',
          'Laravel runs them in APP_TIMEZONE; set SCHEDULE_TIMEZONE=$appZone '
              'to match it.',
        ),
      );
    }
    if (paths != null &&
        connection?.driver == 'sqlite' &&
        systemSqliteConfigured(paths.root)) {
      checks.add(
        const DoctorCheck(
          CheckStatus.warning,
          'pubspec sets sqlite3 source: system but the database is SQLite',
          'Every build then loads SQLite from the OS; remove the hooks block '
              'or install libsqlite3 on the servers.',
        ),
      );
    }
    if (connection?.driver == 'pgsql') {
      // Each isolate has its own pool; leave room for workers, migrations
      // and other clients (a Laravel app on the same database).
      final total = pool * serve.isolates;
      int? limit;
      if (reachable) {
        try {
          final rows = await DB.manager.select('SHOW max_connections');
          limit = int.tryParse('${rows.first['max_connections']}');
        } catch (_) {
          // A proxy such as PgBouncer may not answer SHOW: skipped below.
        }
      }
      if (limit == null) {
        checks.add(
          DoctorCheck(
            CheckStatus.notice,
            'Connection pool: $pool × ${serve.isolates} isolates = $total '
            'per instance (max_connections check skipped)',
            reachable
                ? 'The server did not answer SHOW max_connections.'
                : 'The database is unreachable.',
          ),
        );
      } else if (total > limit * 0.8) {
        checks.add(
          DoctorCheck(
            CheckStatus.warning,
            'Connection pool: $pool × ${serve.isolates} isolates = $total '
                'of max_connections=$limit',
            'Each instance can open $total connections; lower DB_POOL_SIZE '
                'or APP_ISOLATES, or put PgBouncer in front.',
          ),
        );
      } else {
        checks.add(
          DoctorCheck(
            CheckStatus.ok,
            'Connection pool: $pool × ${serve.isolates} isolates = $total '
            'of max_connections=$limit',
          ),
        );
      }
    }
    if (db.sharesSqliteFile(serve.isolates)) {
      checks.add(
        DoctorCheck(
          CheckStatus.notice,
          'SQLite file shared by ${serve.isolates} isolates',
          'SQLite calls are synchronous: a worker waiting for another '
              'isolate\'s write lock (busy_timeout, up to 5 s) blocks its '
              'event loop. Use PostgreSQL for production with '
              'APP_ISOLATES > 1.',
        ),
      );
    }
    final cores = Platform.numberOfProcessors;
    if (serve.isolates == 1 && cores > 1) {
      checks.add(
        DoctorCheck(
          CheckStatus.notice,
          'APP_ISOLATES=1: you are using 1 of $cores cores',
          'Set APP_ISOLATES to the number of cores (or vCPUs) the server '
              'may use, and measure.',
        ),
      );
    }
    final logLevel = LogLevel.parse(env.string('LOG_LEVEL', 'debug'));
    if (logLevel.index < LogLevel.warning.index) {
      checks.add(
        DoctorCheck(
          CheckStatus.notice,
          'LOG_LEVEL=${logLevel.name} is below warning',
          'At info and debug the server writes a line for every request, '
              'which is real I/O at high request rates; LOG_LEVEL=warning '
              'keeps warnings and errors.',
        ),
      );
    }
    if (connection?.driver == 'sqlite' &&
        connection?.database == ':memory:' &&
        serve.isolates > 1) {
      checks.add(
        const DoctorCheck(
          CheckStatus.error,
          'In-memory SQLite cannot be shared across isolates',
          'Use a file database or APP_ISOLATES=1.',
        ),
      );
    }

    try {
      final socket = await ServerSocket.bind(serve.host, serve.port);
      await socket.close();
      checks.add(
        DoctorCheck(CheckStatus.ok, 'Port ${serve.host}:${serve.port} is free'),
      );
    } on SocketException catch (e) {
      checks.add(
        DoctorCheck(
          CheckStatus.warning,
          'Port ${serve.host}:${serve.port} is in use',
          e.message,
        ),
      );
    }

    if (paths != null) {
      final storage = Directory(p.join(paths.root, 'storage'));
      try {
        await storage.create(recursive: true);
        final probe = File(p.join(storage.path, '.doctor'));
        await probe.writeAsString('ok');
        await probe.delete();
        checks.add(const DoctorCheck(CheckStatus.ok, 'storage/ is writable'));
      } on FileSystemException catch (e) {
        checks.add(
          DoctorCheck(CheckStatus.error, 'storage/ is not writable', e.message),
        );
      }
    }

    final metrics = app.config.section<MetricsConfig>();
    if (appConfig.isProduction && metrics.enabled && metrics.token == null) {
      checks.add(
        const DoctorCheck(
          CheckStatus.warning,
          '/metrics is public in production',
          'Set METRICS_TOKEN or expose metrics only on a private network.',
        ),
      );
    }
    final queue = app.config.section<QueueConfig>();
    if (appConfig.isProduction && queue.defaultConnection == 'sync') {
      checks.add(
        const DoctorCheck(
          CheckStatus.warning,
          'QUEUE_CONNECTION=sync in production',
          'Jobs run inside requests; use the database driver and queue:work.',
        ),
      );
    }
    return checks;
  }

  /// What must not reach production: no application key (an error even
  /// without `--production`), password hashing weakened below Laravel's
  /// defaults or with its format check off (warnings, so the gate fails),
  /// and two notes: a plain-`http` `APP_URL` and secrets in a plain `.env`
  /// where `env:encrypt` is available. Nothing here fires outside
  /// `APP_ENV=production`.
  List<DoctorCheck> _productionChecks(
    Application app,
    AppConfig appConfig,
    ProjectPaths? paths,
  ) {
    if (!appConfig.isProduction) {
      return const [];
    }
    final checks = <DoctorCheck>[];
    final key = app.env.maybeString('APP_KEY') ?? '';
    if (key.isEmpty) {
      checks.add(
        const DoctorCheck(
          CheckStatus.error,
          'APP_KEY is not set in production',
          'Encryption, signed URLs and tokens need it: run '
              '`dartisan key:generate`.',
        ),
      );
    }
    final hashing = app.config.section<HashConfig>();
    if (!hashing.verify) {
      checks.add(
        const DoctorCheck(
          CheckStatus.warning,
          'HASH_VERIFY=false in production',
          'Hashes of a weaker format are accepted; set HASH_VERIFY=true.',
        ),
      );
    }
    if (hashing.driver == HashDriver.bcrypt && hashing.bcryptRounds < 10) {
      checks.add(
        DoctorCheck(
          CheckStatus.warning,
          'BCRYPT_ROUNDS=${hashing.bcryptRounds} in production',
          'Laravel uses 12; below 10 passwords are cheap to brute-force.',
        ),
      );
    }
    if (hashing.driver == HashDriver.pbkdf2) {
      checks.add(
        const DoctorCheck(
          CheckStatus.notice,
          'HASH_DRIVER=pbkdf2 in production',
          'bcrypt (the default) or argon2id resist GPU attacks; existing '
              'hashes are upgraded at login.',
        ),
      );
    }
    if (Uri.tryParse(appConfig.url)?.scheme == 'http') {
      checks.add(
        DoctorCheck(
          CheckStatus.notice,
          'APP_URL=${appConfig.url} is plain http',
          'Signed URLs, redirects and links will be served without TLS.',
        ),
      );
    }
    if (ServeOptions.fromEnv(app.env).maxBodyBytes == null) {
      checks.add(
        const DoctorCheck(
          CheckStatus.warning,
          'HTTP_MAX_BODY=0 in production',
          'Requests have no body limit: a client can make a worker buffer '
              'gigabytes. Leave it unset (50 MiB) or set the largest upload '
              'you accept.',
        ),
      );
    }
    if (paths != null &&
        File(p.join(paths.root, '.env')).existsSync() &&
        !File(p.join(paths.root, '.env.encrypted')).existsSync()) {
      checks.add(
        const DoctorCheck(
          CheckStatus.notice,
          'Secrets are in a plain .env',
          '`dartisan env:encrypt` keeps them in .env.encrypted, decrypted in '
              'memory at boot.',
        ),
      );
    }
    return checks;
  }
}

/// `test [--conformance] [--security] [--coverage] [-- dart test args]` —
/// runs the project's tests with `dart test`.
///
/// `--conformance` and `--security` select the tagged suites
/// (`dart_test.yaml`); `--coverage` writes `coverage/` for
/// `package:coverage` / `format_coverage`.
final class TestCommand extends Command<int> {
  TestCommand() {
    argParser
      ..addFlag(
        'conformance',
        negatable: false,
        help: 'Only the Laravel conformance suite (tag "conformance").',
      )
      ..addFlag(
        'security',
        negatable: false,
        help: 'Only the security regression suite (tag "security").',
      )
      ..addFlag(
        'coverage',
        negatable: false,
        help: 'Collect coverage into coverage/.',
      );
  }

  @override
  String get name => 'test';

  @override
  String get description => 'Run the test suite (dart test).';

  @override
  String get invocation => 'dartisan test [options] [-- dart test args]';

  /// The `dart test` arguments for the parsed options.
  static List<String> dartArgs({
    bool conformance = false,
    bool security = false,
    bool coverage = false,
    List<String> rest = const <String>[],
  }) => <String>[
    'test',
    if (conformance) ...['--tags', 'conformance'],
    if (security) ...['--tags', 'security'],
    if (coverage) '--coverage=coverage',
    ...rest,
  ];

  @override
  Future<int> run() async {
    final paths = ProjectPaths.locate();
    final r = argResults!;
    final args = dartArgs(
      conformance: r['conformance'] as bool,
      security: r['security'] as bool,
      coverage: r['coverage'] as bool,
      rest: r.rest,
    );
    stdout.writeln('dart ${args.join(' ')}');
    final process = await Process.start(
      dartExecutable(),
      args,
      workingDirectory: paths.root,
      mode: ProcessStartMode.inheritStdio,
    );
    return process.exitCode;
  }
}

/// `build [--output] [--with-cli] [--docker]` — native app bundle and
/// optional Dockerfile.
///
/// Uses `dart build cli`, which runs build hooks: SQLite (package:sqlite3)
/// is downloaded as a hash-verified prebuilt and placed next to the
/// executable, so servers need no system SQLite. The result is a bundle
/// (`bin/server` + `lib/`), deployed as one directory.
final class BuildCommand extends Command<int> {
  BuildCommand() {
    argParser
      ..addOption(
        'output',
        abbr: 'o',
        help: 'Bundle directory (default: build/server → build/server/bundle).',
      )
      ..addFlag(
        'with-cli',
        negatable: false,
        help: 'Also build bin/dartisan.dart into the same bundle.',
      )
      ..addFlag(
        'docker',
        negatable: false,
        help: 'Write Dockerfile and .dockerignore.',
      )
      ..addFlag(
        'distroless',
        negatable: false,
        help:
            'With --docker: run on gcr.io/distroless/cc (no shell, no package '
            'manager, non-root) instead of debian:bookworm-slim.',
      )
      ..addFlag('no-compile', negatable: false, help: 'Skip the native build.')
      ..addFlag(
        'sqlite',
        defaultsTo: true,
        help:
            'Bundle the SQLite library. --no-sqlite leaves it out for '
            'PostgreSQL and MySQL applications (smaller bundle); a server '
            'that still uses SQLite then needs it from the OS.',
      )
      ..addFlag(
        'force',
        negatable: false,
        help:
            'Overwrite an existing Dockerfile; build --no-sqlite even when '
            'DB_CONNECTION is sqlite.',
      );
  }

  @override
  String get name => 'build';

  @override
  String get description => 'Build the application as a native bundle.';

  @override
  Future<int> run() async {
    final paths = ProjectPaths.locate();
    final r = argResults!;
    if (r['docker'] as bool) {
      final dockerfile = File(p.join(paths.root, 'Dockerfile'));
      if (dockerfile.existsSync() && !(r['force'] as bool)) {
        stdout.writeln('Dockerfile exists (use --force to overwrite).');
      } else {
        final connection =
            projectEnvValue(paths.root, 'DB_CONNECTION') ?? 'sqlite';
        dockerfile.writeAsStringSync(
          dockerfileTemplate(
            sqlite: connection == 'sqlite',
            distroless: r['distroless'] as bool,
          ),
        );
        File(p.join(paths.root, '.dockerignore'))
            .writeAsStringSync(dockerignoreTemplate);
        stdout.writeln(
          'Wrote Dockerfile and .dockerignore.\n'
          '  docker build -t ${paths.packageName} .\n'
          '  docker run -p 8080:8080 -e APP_KEY=... ${paths.packageName}',
        );
      }
    }
    if (r['no-compile'] as bool) {
      return 0;
    }
    final output = r['output'] as String? ?? p.join('build', 'server');
    final targets = [
      'bin/server.dart',
      if (r['with-cli'] as bool) 'bin/dartisan.dart',
    ];
    final withSqlite = r['sqlite'] as bool;
    if (!withSqlite) {
      final connection =
          projectEnvValue(paths.root, 'DB_CONNECTION') ?? 'sqlite';
      if (connection == 'sqlite' && !(r['force'] as bool)) {
        stderr.writeln(
          'DB_CONNECTION is sqlite: without the bundled library the server '
          'would need SQLite from the operating system. Use --force if it '
          'has one (libsqlite3), or build with SQLite.',
        );
        return 1;
      }
    }
    // Only for the build: `dart run` and `dart test` keep the bundled SQLite
    // (tests often use an in-memory database).
    final restore = withSqlite ? null : useSystemSqlite(paths.root);
    try {
      for (final target in targets) {
        final out = target == 'bin/server.dart'
            ? output
            : p.join(p.dirname(output), 'dartisan');
        final args = ['build', 'cli', '-t', target, '-o', out];
        stdout.writeln('dart ${args.join(' ')}');
        final process = await Process.start(
          dartExecutable(),
          args,
          workingDirectory: paths.root,
          mode: ProcessStartMode.inheritStdio,
        );
        final code = await process.exitCode;
        if (code != 0) {
          return code;
        }
      }
    } finally {
      restore?.call();
    }
    if (!withSqlite) {
      removeBundledSqlite(p.join(paths.root, output, 'bundle'));
      stdout.writeln(
        'SQLite left out of the bundle (loaded from the OS if used).',
      );
    }
    if (r['with-cli'] as bool) {
      // One bundle: both executables share bin/ and the bundled lib/.
      final exe = Platform.isWindows ? 'dartisan.exe' : 'dartisan';
      File(
        p.join(paths.root, p.dirname(output), 'dartisan', 'bundle', 'bin', exe),
      ).copySync(p.join(paths.root, output, 'bundle', 'bin', exe));
    }
    final bundle = Directory(p.join(paths.root, output, 'bundle'));
    final size = bundle
        .listSync(recursive: true)
        .whereType<File>()
        .fold<int>(0, (sum, f) => sum + f.lengthSync());
    stdout.writeln(
      'Built ${p.join(output, 'bundle')} '
      '(${(size / 1024 / 1024).toStringAsFixed(1)} MB; run bin/server).',
    );
    return 0;
  }
}

/// `package:sqlite3`'s build-hook setting that loads SQLite from the OS
/// instead of bundling it.
const String systemSqliteHooks = '''
hooks:
  user_defines:
    sqlite3:
      source: system
''';

/// The pubspec whose `hooks.user_defines` the build reads: the project's,
/// or the workspace root's for a workspace member (`resolution: workspace`).
File hooksPubspec(String root) {
  final own = File(p.join(root, 'pubspec.yaml'));
  final member = RegExp(
    r'^resolution:\s*workspace',
    multiLine: true,
  ).hasMatch(own.readAsStringSync());
  if (!member) {
    return own;
  }
  var dir = Directory(root).absolute.parent;
  while (true) {
    final candidate = File(p.join(dir.path, 'pubspec.yaml'));
    if (candidate.existsSync() &&
        RegExp(
          r'^workspace:',
          multiLine: true,
        ).hasMatch(candidate.readAsStringSync())) {
      return candidate;
    }
    final parent = dir.parent;
    if (parent.path == dir.path) {
      return own;
    }
    dir = parent;
  }
}

/// Whether [hooksPubspec] already has `sqlite3: source: system`.
bool systemSqliteConfigured(String root) =>
    RegExp(r'sqlite3:\s*\n\s+source:\s*system')
        .hasMatch(hooksPubspec(root).readAsStringSync());

/// Adds [systemSqliteHooks] to [hooksPubspec] and returns a function that
/// restores the file exactly. When the pubspec already has `hooks:`, it must
/// already say `source: system` (it is never merged); otherwise this throws.
void Function() useSystemSqlite(String root) {
  final pubspec = hooksPubspec(root);
  final original = pubspec.readAsStringSync();
  if (RegExp(r'^hooks:', multiLine: true).hasMatch(original)) {
    if (systemSqliteConfigured(root)) {
      return () {};
    }
    throw StateError(
      '${pubspec.path} already has a hooks: section; add '
      '"sqlite3: source: system" under hooks.user_defines yourself.',
    );
  }
  pubspec.writeAsStringSync('${original.trimRight()}\n\n$systemSqliteHooks');
  return () => pubspec.writeAsStringSync(original);
}

/// Removes SQLite libraries left in [bundle] by an earlier build.
void removeBundledSqlite(String bundle) {
  final lib = Directory(p.join(bundle, 'lib'));
  if (!lib.existsSync()) {
    return;
  }
  for (final file in lib.listSync().whereType<File>()) {
    if (p.basename(file.path).contains('sqlite3')) {
      file.deleteSync();
    }
  }
}

/// [key] from the process environment, else from the project's `.env`.
String? projectEnvValue(String root, String key) {
  final fromProcess = Platform.environment[key];
  if (fromProcess != null && fromProcess.isNotEmpty) {
    return fromProcess;
  }
  final env = File(p.join(root, '.env'));
  if (!env.existsSync()) {
    return null;
  }
  for (final line in env.readAsLinesSync()) {
    final match = RegExp(
      '^\\s*${RegExp.escape(key)}\\s*=\\s*["\']?([^"\'#\\s]*)',
    ).firstMatch(line);
    if (match != null) {
      return match[1];
    }
  }
  return null;
}

/// The `dart` executable to spawn (works under `dart run` and AOT).
String dartExecutable() {
  final current = Platform.resolvedExecutable;
  final base = p.basenameWithoutExtension(current).toLowerCase();
  return base == 'dart' || base == 'dartvm' ? current : 'dart';
}

/// Multi-stage image: Dart SDK builder → slim runtime. SQLite ships inside
/// the bundle (build hooks), so the runtime needs no libsqlite3 package.
/// The generated `Dockerfile`. Without [sqlite] (an application on
/// PostgreSQL or MySQL) the image leaves the SQLite library out, as
/// `dartisan build --no-sqlite` does. With [distroless] the runtime is
/// `gcr.io/distroless/cc-debian12:nonroot`: glibc and CA certificates, no
/// shell or package manager, the `nonroot` user.
String dockerfileTemplate({bool sqlite = true, bool distroless = false}) {
  final dockerfile = distroless ? _distrolessDockerfile : _dockerfile;
  if (sqlite) {
    return dockerfile;
  }
  return dockerfile
      .replaceFirst(
        'RUN dart pub get --offline \\\n',
        '# No SQLite library in the bundle (the database is not SQLite).\n'
            "RUN grep -q '^hooks:' pubspec.yaml || printf "
            r"'\nhooks:\n  user_defines:\n    sqlite3:\n      source: system\n' "
            '>> pubspec.yaml \\\n'
            ' && dart pub get --offline \\\n',
      )
      .replaceFirst(
        '# bin/server and bin/dartisan share the bundled lib/ (SQLite).\n',
        '# bin/server and bin/dartisan (no bundled libraries).\n',
      );
}

const String _dockerfile = r'''
# syntax=docker/dockerfile:1
FROM dart:stable AS build
WORKDIR /app
COPY pubspec.* ./
RUN dart pub get
COPY . .
RUN dart pub get --offline \
 && dart build cli -t bin/server.dart -o build/server \
 && dart build cli -t bin/dartisan.dart -o build/dartisan

FROM debian:bookworm-slim
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates \
 && rm -rf /var/lib/apt/lists/* \
 && useradd --system --home /app daravel
WORKDIR /app
# bin/server and bin/dartisan share the bundled lib/ (SQLite).
COPY --from=build /app/build/server/bundle/ ./
COPY --from=build /app/build/dartisan/bundle/bin/dartisan ./bin/dartisan
RUN mkdir -p storage/logs storage/app database && chown -R daravel /app
USER daravel
# PORT (not APP_PORT) so Cloud Run, Railway, Render and Fly.io can inject theirs.
ENV APP_ENV=production APP_DEBUG=false APP_HOST=0.0.0.0 PORT=8080 \
    LOG_STACK=json
EXPOSE 8080
# Health: GET /up (liveness) and /up/ready (readiness).
CMD ["/app/bin/server"]
''';

/// [_dockerfile] on a distroless runtime. It has no shell, so the build
/// stage prepares the writable directories and the copy gives them to
/// `nonroot` (65532).
const String _distrolessDockerfile = r'''
# syntax=docker/dockerfile:1
FROM dart:stable AS build
WORKDIR /app
COPY pubspec.* ./
RUN dart pub get
COPY . .
RUN dart pub get --offline \
 && dart build cli -t bin/server.dart -o build/server \
 && dart build cli -t bin/dartisan.dart -o build/dartisan \
 && mkdir -p /runtime/storage/logs /runtime/storage/app /runtime/database

FROM gcr.io/distroless/cc-debian12:nonroot
WORKDIR /app
# bin/server and bin/dartisan share the bundled lib/ (SQLite).
COPY --from=build --chown=65532:65532 /app/build/server/bundle/ ./
COPY --from=build --chown=65532:65532 /app/build/dartisan/bundle/bin/dartisan ./bin/dartisan
COPY --from=build --chown=65532:65532 /runtime/ ./
USER nonroot
# PORT (not APP_PORT) so Cloud Run, Railway, Render and Fly.io can inject theirs.
ENV APP_ENV=production APP_DEBUG=false APP_HOST=0.0.0.0 PORT=8080 \
    LOG_STACK=json
EXPOSE 8080
# Health: GET /up (liveness) and /up/ready (readiness). No shell here:
# commands run as `docker exec <container> /app/bin/dartisan migrate`.
CMD ["/app/bin/server"]
''';

const String dockerignoreTemplate = '''
.dart_tool/
build/
.env
.env.*
!.env.example
# Encrypted environments are safe to ship; the key comes from the runtime.
!.env.encrypted
!.env.*.encrypted
*.sqlite*
storage/logs/
.git/
''';

/// `openapi:generate [--output=openapi.json]`
final class OpenApiGenerateCommand extends DaravelCommand {
  OpenApiGenerateCommand(super.createApp) {
    argParser
      ..addOption('output', defaultsTo: 'openapi.json', help: 'Output file.')
      ..addOption('api-version', defaultsTo: '1.0.0', help: 'info.version');
  }

  @override
  String get name => 'openapi:generate';

  @override
  String get description => 'Generate an OpenAPI 3.1 document from the routes.';

  @override
  Future<int> run() => withApp((app) async {
    final document = buildOpenApi(
      app.router.routes,
      title: app.config.section<AppConfig>().name,
      version: argResults!['api-version'] as String,
      serverUrl: app.config.section<AppConfig>().url,
    );
    final output = argResults!['output'] as String;
    final file = File(
      p.isAbsolute(output) ? output : p.join(app.basePath, output),
    );
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert(document),
    );
    stdout.writeln(
      'Wrote ${p.relative(file.path, from: app.basePath)} '
      '(${(document['paths']! as Map).length} path(s)).',
    );
    return 0;
  });
}

/// `model:sync [Model] [--dry-run]` — rewrites the accessor region of
/// models from the database schema (BLUEPRINT_V2 §8.3).
final class ModelSyncCommand extends DaravelCommand {
  ModelSyncCommand(super.createApp) {
    argParser.addFlag(
      'dry-run',
      negatable: false,
      help: 'Print the accessors without writing.',
    );
  }

  @override
  String get name => 'model:sync';

  @override
  String get description => 'Sync model accessors with the database schema.';

  @override
  Future<int> run() => withApp((app) async {
    final paths = ProjectPaths.locate(app.basePath);
    final only = argResults!.rest.isEmpty
        ? null
        : Naming.snake(argResults!.rest.first);
    final dir = Directory(paths.models);
    if (!dir.existsSync()) {
      stdout.writeln('No models found in lib/app/models.');
      return 0;
    }
    final dryRun = argResults!['dry-run'] as bool;
    var synced = 0;
    for (final file in dir.listSync().whereType<File>().where(
      (f) => f.path.endsWith('.dart'),
    )) {
      if (only != null && p.basenameWithoutExtension(file.path) != only) {
        continue;
      }
      final source = file.readAsStringSync();
      final model = ModelSource.parse(source);
      if (model == null) {
        continue;
      }
      if (!await Schema.hasTable(model.table)) {
        stdout.writeln(
          '${model.className}: table [${model.table}] does not exist; run migrate first.',
        );
        continue;
      }
      final plan = planAccessors(model, await Schema.getColumns(model.table));
      for (final warning in plan.warnings) {
        stdout.writeln('${model.className}: $warning');
      }
      final updated = replaceAccessors(source, plan.lines);
      if (updated == null) {
        stdout.writeln(
          '${model.className}: no // <dartisan:accessors> region; skipped.',
        );
        continue;
      }
      if (dryRun) {
        stdout.writeln('--- ${model.className}\n${plan.lines.join('\n')}');
      } else if (updated != source) {
        file.writeAsStringSync(updated);
        stdout.writeln(
          '${model.className}: ${plan.lines.length} accessor line(s) written.',
        );
      } else {
        stdout.writeln('${model.className}: up to date.');
      }
      synced++;
    }
    if (synced == 0) {
      stdout.writeln(
        only == null ? 'No models synced.' : 'Model [$only] not found.',
      );
      return only == null ? 0 : 1;
    }
    return 0;
  });
}

/// `lint [--json]` — runs `daravel_lints` over the project.
final class LintCommand extends Command<int> {
  LintCommand() {
    argParser.addFlag('json', negatable: false, help: 'Output JSON.');
  }

  @override
  String get name => 'lint';

  @override
  String get description =>
      'Check the project with the Daravel lint rules and registries.';

  @override
  Future<int> run() async {
    final root = ProjectPaths.locate().root;
    final issues = lintProject(root);
    if (argResults!['json'] as bool) {
      stdout.writeln(
        jsonEncode([
          for (final i in issues)
            {
              'rule': i.rule,
              'message': i.message,
              'path': i.path,
              'line': i.line,
              'column': i.column,
            },
        ]),
      );
    } else {
      issues.forEach(stdout.writeln);
      stdout.writeln(
        issues.isEmpty ? 'No issues found.' : '${issues.length} issue(s).',
      );
    }
    return issues.isEmpty ? 0 : 1;
  }
}

/// `down [--secret] [--with-secret] [--retry] [--refresh] [--status]
/// [--except]` — puts the application in maintenance mode (Laravel's
/// `storage/framework/down`). Running servers notice within a second.
final class DownCommand extends Command<int> {
  DownCommand({this.root}) {
    argParser
      ..addOption('secret', help: 'Path that sets a bypass cookie (/<secret>).')
      ..addFlag(
        'with-secret',
        negatable: false,
        help: 'Generate the bypass secret.',
      )
      ..addOption('retry', help: 'Retry-After header, in seconds.')
      ..addOption('refresh', help: 'Refresh header, in seconds.')
      ..addOption('status', defaultsTo: '503', help: 'Response status.')
      ..addMultiOption('except', help: 'Paths that stay available.');
  }

  /// Project root; located from the working directory when `null`.
  final String? root;

  @override
  String get name => 'down';

  @override
  String get description => 'Put the application into maintenance mode.';

  @override
  Future<int> run() async {
    final args = argResults!;
    int? number(String option) {
      final value = args[option] as String?;
      if (value == null) {
        return null;
      }
      return int.tryParse(value) ??
          usageException('--$option must be an integer, got "$value".');
    }

    final secret =
        args['secret'] as String? ??
        ((args['with-secret'] as bool) ? Str.random(32) : null);
    MaintenanceMode.at(root ?? ProjectPaths.locate().root).activate(
      secret: secret,
      retry: number('retry'),
      refresh: number('refresh'),
      status: number('status') ?? 503,
      except: [for (final path in args['except'] as List<String>) path],
    );
    stdout.writeln('Application is now in maintenance mode.');
    if (secret != null) {
      stdout.writeln('Bypass: visit /$secret to set the bypass cookie.');
    }
    return 0;
  }
}

/// `up` — brings the application out of maintenance mode.
final class UpCommand extends Command<int> {
  UpCommand({this.root});

  /// Project root; located from the working directory when `null`.
  final String? root;

  @override
  String get name => 'up';

  @override
  String get description => 'Bring the application out of maintenance mode.';

  @override
  Future<int> run() async {
    final wasDown = MaintenanceMode.at(root ?? ProjectPaths.locate().root)
        .deactivate();
    stdout.writeln(
      wasDown ? 'Application is now live.' : 'Application is already up.',
    );
    return 0;
  }
}
