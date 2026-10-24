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
enum CheckStatus { ok, warning, error }

final class DoctorCheck {
  const DoctorCheck(this.status, this.title, [this.detail]);

  final CheckStatus status;
  final String title;
  final String? detail;

  String get symbol => switch (status) {
    .ok => '[ok]  ',
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
    final checks = await diagnose();
    for (final check in checks) {
      stdout.writeln(
        '${check.symbol} ${check.title}'
        '${check.detail == null ? '' : '\n         ${check.detail}'}',
      );
    }
    final strict = argResults!['production'] as bool;
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

  /// Runs every check (also used by tests).
  Future<List<DoctorCheck>> diagnose() async {
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
      if (!env.existsSync()) {
        checks.add(
          const DoctorCheck(
            CheckStatus.warning,
            '.env is missing',
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
        checks.addAll(await _appChecks(app, paths));
      });
    } finally {
      await app.shutdown();
    }
    return checks;
  }

  Future<List<DoctorCheck>> _appChecks(
    Application app,
    ProjectPaths? paths,
  ) async {
    final checks = <DoctorCheck>[];
    final appConfig = app.config.section<AppConfig>();
    final env = app.env;
    checks.add(
      DoctorCheck(
        CheckStatus.ok,
        'Application boots (APP_ENV=${appConfig.env})',
      ),
    );

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
    try {
      await DB.manager.select('SELECT 1');
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
    final pool = env.integer('DB_POOL_SIZE', 10);
    final connection = db.connections[db.defaultConnection];
    if (connection?.driver == 'pgsql' && pool * serve.isolates > 100) {
      checks.add(
        DoctorCheck(
          CheckStatus.warning,
          'Connection pool: $pool × ${serve.isolates} isolates = '
              '${pool * serve.isolates} connections',
          'PostgreSQL allows 100 by default; lower DB_POOL_SIZE.',
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
      ..addFlag('no-compile', negatable: false, help: 'Skip the native build.')
      ..addFlag(
        'force',
        negatable: false,
        help: 'Overwrite an existing Dockerfile.',
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
        dockerfile.writeAsStringSync(dockerfileTemplate());
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

/// The `dart` executable to spawn (works under `dart run` and AOT).
String dartExecutable() {
  final current = Platform.resolvedExecutable;
  final base = p.basenameWithoutExtension(current).toLowerCase();
  return base == 'dart' || base == 'dartvm' ? current : 'dart';
}

/// Multi-stage image: Dart SDK builder → slim runtime. SQLite ships inside
/// the bundle (build hooks), so the runtime needs no libsqlite3 package.
String dockerfileTemplate() => r'''
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
ENV APP_ENV=production APP_DEBUG=false APP_HOST=0.0.0.0 APP_PORT=8080 \
    LOG_STACK=json
EXPOSE 8080
# Health: GET /up (liveness) and /up/ready (readiness).
CMD ["/app/bin/server"]
''';

const String dockerignoreTemplate = '''
.dart_tool/
build/
.env
.env.*
!.env.example
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
