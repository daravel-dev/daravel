import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:daravel_horizon/daravel_horizon.dart';
import 'package:test/test.dart';

final String dbPath =
    '${Directory.systemTemp.path}${Platform.pathSeparator}horizon_policy_$pid.sqlite';

Application policyApp(Map<String, String> env) =>
    Application.configure(basePath: _basePath())
        .withEnv({
          'APP_ENV': 'testing',
          'DB_CONNECTION': 'sqlite',
          'DB_DATABASE': dbPath,
          'HORIZON_ALLOW_SQLITE': 'true',
          ...env,
        })
        .withLogLevel(LogLevel.critical)
        .withHorizon(createApp: () => policyApp(env))
        .create();

Future<HorizonKillPolicy> policyOf(Map<String, String> env) async {
  final app = policyApp(env);
  await app.boot();
  addTearDown(app.shutdown);
  return app.run(() => horizonKillPolicy(app));
}

void main() {
  test('a SQLite file queue: a kill needs a fresh process', () async {
    final policy = await policyOf({'QUEUE_CONNECTION': 'database'});
    expect(policy.restartAfterKill, 'sqlite_lock');
    expect(policy.terminate, isNull);
    expect(policy.idleTransactionTimeout, const Duration(seconds: 73));
  });

  test('SQLite with another queue: nothing to end, no restart', () async {
    final policy = await policyOf({'QUEUE_CONNECTION': 'memory'});
    expect(policy.restartAfterKill, isNull);
    expect(policy.terminate, isNull);
  });

  test('the environment\'s DB_IDLE_TRANSACTION_TIMEOUT wins', () async {
    final policy = await policyOf({
      'QUEUE_CONNECTION': 'memory',
      'DB_IDLE_TRANSACTION_TIMEOUT': '600',
    });
    expect(policy.idleTransactionTimeout, isNull);
  });

  final pgUrl = Platform.environment['DARAVEL_TEST_PG'];
  test(
    'PostgreSQL: sessions are ended through the application\'s driver',
    () async {
      final policy = await policyOf({
        'DB_CONNECTION': 'pgsql',
        'DB_URL': pgUrl!,
        'QUEUE_CONNECTION': 'memory',
      });
      expect(policy.restartAfterKill, isNull);
      expect(policy.terminate, isNotNull);
      expect(await policy.terminate!('pgsql', '2147483000'), isFalse);
    },
    tags: ['integration'],
    skip: pgUrl == null || pgUrl.isEmpty ? 'needs DARAVEL_TEST_PG' : false,
  );
}

/// This file's own directory, by name and pid: the master and its worker
/// isolates share it (the file signal store, Horizon's status), and test
/// files running in parallel do not.
String _basePath() => (Directory(
  '${Directory.systemTemp.path}${Platform.pathSeparator}horizon_policy_base_$pid',
)..createSync(recursive: true)).path;
