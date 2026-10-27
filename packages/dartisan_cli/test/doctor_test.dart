import 'dart:convert';
import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:daravel/daravel.dart';
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

  test('notices never fail doctor --production', () async {
    final runner = CommandRunner<int>('dartisan', 'test')
      ..addCommand(
        DoctorCommand(appWith({'APP_ISOLATES': '4', 'LOG_LEVEL': 'debug'})),
      );
    final code = await inProject(() async {
      return await runner.run(['doctor', '--production']) ?? 0;
    });
    expect(code, 0);
  });
}
