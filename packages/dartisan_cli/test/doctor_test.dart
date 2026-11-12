import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:daravel/daravel.dart';
import 'package:daravel_mysql/daravel_mysql.dart';
import 'package:dartisan_cli/dartisan_cli.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// `doctor`: the tuning notices (worker count, log level, SQLite under
/// several isolates, the PostgreSQL pool) and that a notice never fails
/// `doctor --production`, which deployments use as a gate.
void main() {
  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('dartisan_doctor');
    File(p.join(root.path, 'pubspec.yaml')).writeAsStringSync('name: demo\n');
    Directory(p.join(root.path, 'bootstrap')).createSync();
    File(p.join(root.path, '.env')).writeAsStringSync('');
  });
  tearDown(() => root.deleteSync(recursive: true));

  AppFactory appWith(Map<String, String> env) =>
      () => Application.configure(basePath: root.path).withEnv({
        'APP_ENV': 'local',
        'APP_KEY': 'base64:${base64.encode(List<int>.filled(32, 7))}',
        'APP_PORT': '0',
        'DB_DATABASE': p.join(root.path, 'database.sqlite'),
        ...env,
      }).create();

  Future<T> inProject<T>(Future<T> Function() body) =>
      IOOverrides.runZoned(body, getCurrentDirectory: () => root);

  Future<List<DoctorCheck>> diagnose(Map<String, String> env) =>
      inProject(() => DoctorCommand(appWith(env)).diagnose());

  List<String> notices(List<DoctorCheck> checks) => [
    for (final c in checks)
      if (c.status == CheckStatus.notice) c.title,
  ];

  test('notes a SQLite file shared by several isolates', () async {
    final checks = await diagnose({'APP_ISOLATES': '4'});
    expect(notices(checks), contains('SQLite file shared by 4 isolates'));
  });

  test('notes a log level below warning, not warning itself', () async {
    expect(
      notices(await diagnose({'LOG_LEVEL': 'info'})),
      contains('LOG_LEVEL=info is below warning'),
    );
    expect(
      notices(await diagnose({'LOG_LEVEL': 'warning'})),
      isNot(contains(startsWith('LOG_LEVEL'))),
    );
  });

  test('notes one isolate on a machine with more cores', () async {
    final titles = notices(await diagnose({'APP_ISOLATES': '1'}));
    if (Platform.numberOfProcessors > 1) {
      expect(
        titles,
        contains(
          'APP_ISOLATES=1: you are using 1 of '
          '${Platform.numberOfProcessors} cores',
        ),
      );
    } else {
      expect(titles, isNot(contains(startsWith('APP_ISOLATES=1'))));
    }
  });

  test(
    'skips the max_connections check when PostgreSQL is unreachable',
    () async {
      final checks = await diagnose({
        'DB_CONNECTION': 'pgsql',
        'DB_HOST': '127.0.0.1',
        // Nothing listens on port 1.
        'DB_PORT': '1',
        'DB_POOL_SIZE': '5',
        'APP_ISOLATES': '3',
      });
      expect(
        notices(checks),
        contains(
          'Connection pool: 5 × 3 isolates = 15 per instance '
          '(max_connections check skipped)',
        ),
      );
    },
  );

  test(
    'the pool formula counts APP_PROCESSES and the embedded workers',
    () async {
      // Each of the 2 processes runs 3 HTTP isolates plus the embedded
      // queue worker and scheduler, each with a pool of 5: 50 connections.
      final checks = await diagnose({
        'DB_CONNECTION': 'pgsql',
        'DB_HOST': '127.0.0.1',
        'DB_PORT': '1',
        'DB_POOL_SIZE': '5',
        'APP_ISOLATES': '3',
        'APP_PROCESSES': '2',
        'SERVER_EMBED_QUEUE': 'true',
        'SERVER_EMBED_SCHEDULER': 'true',
      });
      expect(
        notices(checks),
        contains(
          'Connection pool: 5 × (3 isolates + 2 embedded) × 2 processes = 50 '
          'per instance (max_connections check skipped)',
        ),
      );
    },
  );

  test('the pool check covers MySQL and MariaDB too', () async {
    for (final driver in ['mysql', 'mariadb']) {
      final checks = await diagnose({
        'DB_CONNECTION': driver,
        'DB_HOST': '127.0.0.1',
        'DB_PORT': '1',
        'DB_POOL_SIZE': '4',
        'APP_ISOLATES': '2',
      });
      expect(
        notices(checks),
        contains(
          'Connection pool: 4 × 2 isolates = 8 per instance '
          '(max_connections check skipped)',
        ),
        reason: driver,
      );
    }
  });

  test(
    'compares the pool with max_connections of a MySQL/MariaDB server',
    () async {
      final url = Platform.environment['DARAVEL_TEST_MYSQL']!;
      Application factory() => Application.configure(basePath: root.path)
          .withDatabaseDriver('mysql', MySqlDriver.fromConfig)
          .withDatabaseDriver('mariadb', MySqlDriver.fromConfig)
          .withEnv({
            'APP_ENV': 'local',
            'APP_KEY': 'base64:${base64.encode(List<int>.filled(32, 7))}',
            'APP_PORT': '0',
            'DB_URL': url,
            'APP_ISOLATES': '2',
          })
          .create();
      final checks = await inProject(() => DoctorCommand(factory).diagnose());
      final pool = [
        for (final c in checks)
          if (c.title.startsWith('Connection pool:')) c,
      ];
      expect(pool, hasLength(1));
      // `pool=` in the URL or DB_POOL_SIZE (10) times 2 isolates, against
      // the server's real limit (151 on MySQL, 151 on MariaDB by default).
      expect(
        pool.single.title,
        matches(
          RegExp(
            r'^Connection pool: \d+ × 2 isolates = \d+ of '
            r'max_connections=\d+$',
          ),
        ),
      );
      expect(pool.single.status, isNot(CheckStatus.notice));
    },
    skip: (Platform.environment['DARAVEL_TEST_MYSQL'] ?? '').isEmpty
        ? 'DARAVEL_TEST_MYSQL not set'
        : false,
  );

  Future<int> gate(Map<String, String> env) async {
    final runner = CommandRunner<int>('dartisan', 'test')
      ..addCommand(DoctorCommand(appWith(env)));
    return await inProject<int?>(
          () => runner.run(['doctor', '--production']),
        ) ??
        0;
  }

  List<String> titled(List<DoctorCheck> checks, CheckStatus status) => [
    for (final c in checks)
      if (c.status == status) c.title,
  ];

  test('notices never fail doctor --production', () async {
    final code = await gate({
      'APP_ENV': 'production',
      'QUEUE_CONNECTION': 'database',
      'APP_ISOLATES': '4',
      'LOG_LEVEL': 'debug',
      // Notes under production, never failures.
      'APP_URL': 'http://api.example.test',
      'HASH_DRIVER': 'pbkdf2',
    });
    expect(code, 0);
  });

  Future<List<DoctorCheck>> diagnoseProduction(Map<String, String> env) =>
      inProject(
        () =>
            DoctorCommand(appWith({'APP_ENV': 'production', ...env}))
                .diagnose(production: true),
      );

  const vmOption = 'DART_VM_OPTIONS=--new_gen_semi_max_size=128';

  test('--production suggests processes for four isolates in one', () async {
    final checks = await diagnoseProduction({'APP_ISOLATES': '4'});
    final advice = checks.singleWhere(
      (c) => c.title == 'APP_ISOLATES=4 in one process',
    );
    expect(advice.status, CheckStatus.notice);
    final half = Platform.numberOfProcessors ~/ 2;
    expect(
      advice.detail,
      contains('try APP_PROCESSES=${half < 1 ? 1 : half} with APP_ISOLATES=2'),
    );
    // Advice for production only: plain doctor stays quiet.
    expect(
      notices(await diagnose({'APP_ISOLATES': '4'})),
      isNot(contains('APP_ISOLATES=4 in one process')),
    );
  });

  test('no process advice once APP_PROCESSES > 1', () async {
    final checks = await diagnoseProduction({
      'APP_ISOLATES': '4',
      'APP_PROCESSES': '2',
      'CACHE_STORE': 'database',
      'CACHE_LIMITER': 'database',
      'QUEUE_UNIQUE_LOCK_STORE': 'database',
    });
    expect([
      for (final c in checks) c.title,
    ], isNot(contains(startsWith('APP_ISOLATES=4'))));
    expect(
      titled(checks, CheckStatus.error),
      isNot(contains(startsWith('APP_PROCESSES='))),
    );
    // The stores serve refuses with several processes (ADR-027).
    final unshared = await diagnoseProduction({
      'APP_ISOLATES': '2',
      'APP_PROCESSES': '2',
    });
    expect(
      titled(unshared, CheckStatus.error),
      contains(
        'APP_PROCESSES=2 with per-process state: CACHE_STORE=memory, '
        'CACHE_LIMITER=process, QUEUE_UNIQUE_LOCK_STORE=process',
      ),
    );
    final accepted = await diagnoseProduction({
      'APP_ISOLATES': '2',
      'APP_PROCESSES': '2',
      'APP_PROCESSES_ALLOW_UNSHARED_STATE': 'true',
    });
    expect(
      titled(accepted, CheckStatus.error),
      isNot(contains(startsWith('APP_PROCESSES='))),
    );
  });

  test('--production prints the VM option with several workers', () async {
    for (final env in [
      {'APP_ISOLATES': '2'},
      {
        'APP_ISOLATES': '1',
        'APP_PROCESSES': '2',
        'APP_PROCESSES_ALLOW_UNSHARED_STATE': 'true',
      },
    ]) {
      expect(
        notices(await diagnoseProduction(env)),
        contains(vmOption),
        reason: '$env',
      );
    }
    expect(
      notices(await diagnoseProduction({'APP_ISOLATES': '1'})),
      isNot(contains(vmOption)),
    );
  });

  test('doctor --production needs APP_ENV=production', () async {
    // The production-only checks are skipped under any other environment,
    // so the gate used to pass on a configuration never deployed as such.
    expect(await gate({'APP_ENV': 'local'}), 1);
    final checks = await inProject(
      () =>
          DoctorCommand(appWith({'APP_ENV': 'staging'}))
              .diagnose(production: true),
    );
    expect(titled(checks, CheckStatus.error), [
      'doctor --production with APP_ENV=staging',
    ]);
    // Without the flag the same configuration is not an error.
    expect(
      titled(await diagnose({'APP_ENV': 'staging'}), CheckStatus.error),
      isEmpty,
    );
  });

  test('production: a JWT denylist in a volatile cache store warns', () async {
    AppFactory jwtApp(Map<String, String> env) =>
        () => Application.configure(basePath: root.path)
            .withEnv({
              'APP_ENV': 'production',
              'APP_KEY': 'base64:${base64.encode(List<int>.filled(32, 7))}',
              'APP_PORT': '0',
              'DB_DATABASE': p.join(root.path, 'database.sqlite'),
              ...env,
            })
            .withAuth(
              (auth) => auth.jwt<DoctorUser>(
                'jwt',
                ModelUserProvider<DoctorUser>(DoctorUser.definition),
              ),
            )
            .create();
    Future<List<String>> warnings(Map<String, String> env) async => titled(
      await inProject(() => DoctorCommand(jwtApp(env)).diagnose()),
      CheckStatus.warning,
    );
    expect(
      await warnings(const {}),
      contains('JWT denylist in the memory cache store in production'),
    );
    expect(
      await warnings(const {'CACHE_STORE': 'process'}),
      contains('JWT denylist in the process cache store in production'),
    );
    expect(
      await warnings(const {'CACHE_STORE': 'database'}),
      isNot(contains(startsWith('JWT denylist'))),
    );
    // Without a JWT guard the store does not matter.
    expect(
      titled(await diagnose({'APP_ENV': 'production'}), CheckStatus.warning),
      isNot(contains(startsWith('JWT denylist'))),
    );
  });

  test('production: header and multipart limits turned off warn', () async {
    final checks = await diagnose({
      'APP_ENV': 'production',
      'HTTP_MAX_HEADER_BYTES': '0',
      'HTTP_MAX_HEADERS': '0',
      'HTTP_MULTIPART_MAX_PARTS': '0',
      'HTTP_MULTIPART_MAX_PART_HEADER_BYTES': '0',
    });
    expect(
      titled(checks, CheckStatus.warning),
      containsAll([
        'HTTP_MAX_HEADER_BYTES, HTTP_MAX_HEADERS=0 in production',
        'HTTP_MULTIPART_MAX_PARTS, HTTP_MULTIPART_MAX_PART_HEADER_BYTES=0 '
            'in production',
      ]),
    );
    // The defaults (unset) do not warn.
    final defaults = await diagnose({'APP_ENV': 'production'});
    expect(
      titled(defaults, CheckStatus.warning),
      isNot(contains(contains('HTTP_MAX_HEADER'))),
    );
    expect(
      titled(defaults, CheckStatus.warning),
      isNot(contains(contains('HTTP_MULTIPART'))),
    );
  });

  test('production: a JSON depth off or above 1 024 warns', () async {
    Future<List<String>> warned(Map<String, String> env) async => titled(
      await diagnose({'APP_ENV': 'production', ...env}),
      CheckStatus.warning,
    ).where((title) => title.startsWith('HTTP_JSON_MAX_DEPTH')).toList();
    expect(await warned(const {}), isEmpty, reason: 'the default, 512');
    expect(await warned(const {'HTTP_JSON_MAX_DEPTH': '1024'}), isEmpty);
    expect(await warned(const {'HTTP_JSON_MAX_DEPTH': '64'}), isEmpty);
    expect(await warned(const {'HTTP_JSON_MAX_DEPTH': '1025'}), [
      'HTTP_JSON_MAX_DEPTH=1025 in production',
    ]);
    expect(await warned(const {'HTTP_JSON_MAX_DEPTH': '0'}), [
      'HTTP_JSON_MAX_DEPTH=0 in production',
    ]);
  });

  test('production: no APP_KEY is an error, weak hashing warns', () async {
    final checks = await diagnose({
      'APP_ENV': 'production',
      'APP_KEY': '',
      'HASH_VERIFY': 'false',
      'BCRYPT_ROUNDS': '4',
      'APP_URL': 'http://api.example.test',
      'HTTP_MAX_BODY': '0',
    });
    expect(
      titled(checks, CheckStatus.error),
      contains('APP_KEY is not set in production'),
    );
    expect(
      titled(checks, CheckStatus.warning),
      containsAll([
        'HASH_VERIFY=false in production',
        'BCRYPT_ROUNDS=4 in production',
        'HTTP_MAX_BODY=0 in production',
      ]),
    );
    expect(
      notices(checks),
      containsAll([
        'APP_URL=http://api.example.test is plain http',
        'Secrets are in a plain .env',
      ]),
    );
    expect(
      notices(checks),
      isNot(contains('APP_URL is https; the server itself speaks plain HTTP')),
    );
    // TLS ends at a proxy: requests see https only from a trusted one.
    final https = await diagnose({
      'APP_ENV': 'production',
      'APP_URL': 'https://api.example.test',
    });
    expect(
      notices(https),
      contains('APP_URL is https; the server itself speaks plain HTTP'),
    );
    // Laravel's defaults pass, and none of it fires outside production.
    final defaults = await diagnose({'APP_ENV': 'production'});
    expect(
      titled(defaults, CheckStatus.warning),
      isNot(contains(startsWith('HASH_'))),
    );
    final local = await diagnose({
      'APP_KEY': '',
      'HASH_VERIFY': 'false',
      'BCRYPT_ROUNDS': '4',
    });
    expect([
      ...titled(local, CheckStatus.error),
      ...titled(local, CheckStatus.warning),
    ], isNot(contains(contains('in production'))));
  });

  test('DB_IDLE_TRANSACTION_TIMEOUT: shown for PostgreSQL and MariaDB, a '
      'notice on MySQL', () {
    ConnectionConfig of(String driver, [String? seconds]) => ConnectionConfig(
      driver: driver,
      database: 'app',
      options: {'idle_transaction_timeout': seconds},
    );
    expect(idleTransactionTimeoutCheck(null), isNull);
    expect(idleTransactionTimeoutCheck(of('pgsql')), isNull);
    expect(idleTransactionTimeoutCheck(of('pgsql', '0')), isNull);
    final pgsql = idleTransactionTimeoutCheck(of('pgsql', '15'))!;
    expect(pgsql.status, CheckStatus.ok);
    expect(pgsql.title, 'Idle transaction timeout: 15s');
    expect(pgsql.detail, contains('idle_in_transaction_session_timeout'));
    expect(
      idleTransactionTimeoutCheck(of('mariadb', '15'))!.detail,
      contains('(idle_transaction_timeout)'),
    );
    expect(
      idleTransactionTimeoutCheck(of('mysql', '15'))!.status,
      CheckStatus.notice,
    );
    expect(idleTransactionTimeoutCheck(of('sqlite', '15')), isNull);
  });

  test("package_config.json resolved on another system", () {
    final dir = Directory(p.join(root.path, ".dart_tool"))..createSync();
    final config = File(p.join(dir.path, "package_config.json"));
    expect(
      packageConfigCheck(root.path, windows: false),
      isNull,
      reason: "no file",
    );

    config.writeAsStringSync(
      '{"packages": [{"name": "daravel", "rootUri": "file:///C:/Users/dev/AppData/Local/Pub/Cache/hosted/pub.dev/daravel-1.17.0"}]}',
    );
    final linux = packageConfigCheck(root.path, windows: false);
    expect(linux?.status, CheckStatus.error);
    expect(linux?.detail, contains("ddev exec dart pub get"));
    expect(packageConfigCheck(root.path, windows: true), isNull);

    config.writeAsStringSync(
      '{"packages": [{"name": "daravel", "rootUri": "file:///home/dev/.pub-cache/hosted/pub.dev/daravel-1.17.0"}, {"name": "app", "rootUri": "../"}]}',
    );
    expect(packageConfigCheck(root.path, windows: false), isNull);
    expect(
      packageConfigCheck(root.path, windows: true)?.status,
      CheckStatus.error,
    );
  });

  test(
    'doctor --fix-tooling resolves the packages again on this system',
    timeout: const Timeout(Duration(minutes: 2)),
    () async {
      // A package_config.json from the other kind of system.
      final dir = Directory(p.join(root.path, '.dart_tool'))..createSync();
      final foreign = Platform.isWindows
          ? 'file:///home/dev/.pub-cache/hosted/pub.dev/path-1.9.0'
          : 'file:///C:/Users/dev/AppData/Local/Pub/Cache/hosted/pub.dev/path-1.9.0';
      File(p.join(dir.path, 'package_config.json')).writeAsStringSync(
        '{"configVersion": 2, "packages": [{"name": "path", "rootUri": "$foreign", "packageUri": "lib/"}]}',
      );
      File(p.join(root.path, 'pubspec.yaml'))
          .writeAsStringSync('name: demo\nenvironment:\n  sdk: ^3.0.0\n');
      final broken = await inProject(
        () => DoctorCommand(appWith(const {})).diagnose(),
      );
      expect(
        titled(broken, CheckStatus.error),
        contains(startsWith('Packages resolved on')),
      );
      final fixed = await inProject(
        () => DoctorCommand(appWith(const {})).diagnose(fixTooling: true),
      );
      expect(
        titled(fixed, CheckStatus.error),
        isNot(contains(startsWith('Packages resolved on'))),
      );
      expect(
        titled(fixed, CheckStatus.ok),
        contains('Packages resolved again on this system (--fix-tooling)'),
      );
      expect(
        packageConfigCheck(root.path, windows: Platform.isWindows),
        isNull,
      );
    },
  );
}

/// A user model for the JWT guard of the denylist check.
final class DoctorUser extends Model with AuthenticatableModel {
  static final ModelDefinition<DoctorUser> definition =
      ModelDefinition<DoctorUser>(table: 'users', factory: DoctorUser.new);

  @override
  ModelDefinition<DoctorUser> get modelDefinition => DoctorUser.definition;
}
