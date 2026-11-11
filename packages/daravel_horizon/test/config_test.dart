import 'package:daravel/daravel.dart';
import 'package:daravel_horizon/daravel_horizon.dart';
import 'package:test/test.dart';

void main() {
  const one = SupervisorPlan(name: SupervisorName('supervisor-1'));

  test('HORIZON_* scalars, defaults and the APP_ENV plans', () {
    final config = HorizonConfig.fromEnv(
      Env.fromMap({
        'APP_ENV': 'production',
        'HORIZON_STORE': 'database',
        'HORIZON_PATH': '/ops/horizon',
        'HORIZON_MEMORY_LIMIT': '512',
        'HORIZON_EWMA_ALPHA': '0.5',
      }),
      defaults: const [
        one,
        SupervisorPlan(
          name: SupervisorName('mail'),
          queues: [QueueName('mail')],
        ),
      ],
      environments: const {
        'production': [
          SupervisorPlan(
            name: SupervisorName('supervisor-1'),
            maxProcesses: 10,
          ),
          SupervisorPlan(name: SupervisorName('reports')),
        ],
        'local': [SupervisorPlan(name: SupervisorName('supervisor-1'))],
      },
    );
    expect(config.store, 'database');
    expect(config.path, '/ops/horizon');
    expect(config.memoryLimit, 512);
    expect(config.ewmaAlpha, 0.5);
    expect(
      [for (final p in config.plans) p.name.value],
      ['supervisor-1', 'mail', 'reports'],
    );
    expect(config.plans.first.maxProcesses, 10);
    expect(config.waitFor('database', 'default'), const Duration(seconds: 60));
    final map = config.toMap();
    expect(map['store'], 'database');
    expect((map['defaults']! as List).length, 3);
  });

  Future<List<ConfigIssue>> issues(
    HorizonConfig horizon, {
    Map<String, String> env = const {},
  }) async {
    final config = ConfigRepository()
      ..register<HorizonConfig>(horizon)
      ..register<QueueConfig>(const QueueConfig(defaultConnection: 'database'));
    return HorizonConfig.check(Env.fromMap(env), config).toList();
  }

  test(
    'check: a heartbeat under 250 ms is a warning, except in testing',
    () async {
      const fast = HorizonConfig(heartbeat: Duration(milliseconds: 100));
      final found = await issues(fast);
      expect(found.single.level, ConfigIssueLevel.warning);
      expect(found.single.message, contains('HORIZON_HEARTBEAT_MS=100'));
      expect(await issues(fast, env: const {'APP_ENV': 'testing'}), isEmpty);
      expect(
        await issues(
          const HorizonConfig(heartbeat: Duration(milliseconds: 250)),
        ),
        isEmpty,
      );
    },
  );

  test('check: bounds, names, waits and the store', () async {
    expect(await issues(const HorizonConfig()), isEmpty);
    final bad = await issues(
      const HorizonConfig(
        store: 'memcached',
        waits: {'database:reports': Duration(seconds: 30)},
        plans: [
          SupervisorPlan(
            name: SupervisorName('a'),
            minProcesses: -1,
            maxProcesses: 0,
            balanceMaxShift: 0,
          ),
          SupervisorPlan(name: SupervisorName('a'), queues: []),
        ],
      ),
    );
    final messages = [for (final i in bad) '${i.level.name}: ${i.message}'];
    expect(messages, [
      contains('minProcesses must be 0'),
      contains('maxProcesses (0) must be at least 1'),
      contains('balanceMaxShift'),
      contains('defined twice'),
      contains('has no queues'),
      startsWith('warning: Horizon waits names [database:reports]'),
      contains('HORIZON_STORE=memcached'),
    ]);
  });

  test('check: a plan timeout plus killGrace past QUEUE_RETRY_AFTER is a '
      'warning (a blocked worker is killed at retry_after)', () async {
    final found = await issues(
      const HorizonConfig(
        plans: [
          SupervisorPlan(
            name: SupervisorName('long'),
            timeout: Duration(seconds: 85),
          ),
          SupervisorPlan(
            name: SupervisorName('short'),
            timeout: Duration(seconds: 70),
          ),
        ],
      ),
    );
    // retry_after 90 s by default; killGrace 10 s.
    expect(found.single.level, ConfigIssueLevel.warning);
    expect(found.single.message, contains('[long]'));
    expect(found.single.message, contains('QUEUE_RETRY_AFTER (90s)'));
  });

  test('HORIZON_IDLE_TX_TIMEOUT: by default the longest plan timeout plus '
      'killGrace and three heartbeats; 0 turns it off', () {
    HorizonConfig of(Map<String, String> env, {List<SupervisorPlan>? plans}) =>
        HorizonConfig.fromEnv(Env.fromMap(env), defaults: plans ?? [one]);
    // No plan timeout: 60 s + 10 s + 3 × 1 s.
    expect(of({}).workerIdleTransactionTimeout, const Duration(seconds: 73));
    expect(
      of(
        {'HORIZON_KILL_GRACE': '5', 'HORIZON_HEARTBEAT_MS': '200'},
        plans: const [
          SupervisorPlan(
            name: SupervisorName('a'),
            timeout: Duration(seconds: 90),
          ),
          SupervisorPlan(
            name: SupervisorName('b'),
            timeout: Duration(seconds: 20),
          ),
        ],
      ).workerIdleTransactionTimeout,
      const Duration(seconds: 96),
      reason: '90 + 5 + 0.6, rounded up',
    );
    expect(
      of({'HORIZON_IDLE_TX_TIMEOUT': '30'}).workerIdleTransactionTimeout,
      const Duration(seconds: 30),
    );
    expect(
      of({'HORIZON_IDLE_TX_TIMEOUT': '0'}).workerIdleTransactionTimeout,
      isNull,
    );
    expect(of({}).toMap()['idle_tx_timeout'], 73);
  });

  test('sessions travel as one string', () {
    final sessions = {
      'pgsql': ['812', '815'],
      'audit': ['901'],
      'empty': <String>[],
    };
    expect(encodeSessions(sessions), 'pgsql=812,815;audit=901');
    expect(decodeSessions(encodeSessions(sessions)), {
      'pgsql': ['812', '815'],
      'audit': ['901'],
    });
    expect(decodeSessions(''), isEmpty);
  });

  test('minProcesses 0 is allowed (scale to zero)', () async {
    expect(
      await issues(
        const HorizonConfig(
          plans: [
            SupervisorPlan(
              name: SupervisorName('a'),
              minProcesses: 0,
              maxProcesses: 4,
            ),
          ],
        ),
      ),
      isEmpty,
    );
  });

  group('SQLite (ACK 157)', () {
    ConfigRepository repo(HorizonConfig horizon, {String db = 'app.sqlite'}) =>
        ConfigRepository()
          ..register<HorizonConfig>(horizon)
          ..register<QueueConfig>(
            const QueueConfig(defaultConnection: 'database'),
          )
          ..register<DatabaseConfig>(
            DatabaseConfig(
              defaultConnection: 'sqlite',
              connections: {
                'sqlite': ConnectionConfig(driver: 'sqlite', database: db),
              },
            ),
          );
    final embed = Env.fromMap({'SERVER_EMBED_WORKERS': 'horizon'});

    test('embedded on a SQLite file is refused unless allowed', () {
      final refused = HorizonConfig.check(
        embed,
        repo(const HorizonConfig()),
      ).toList();
      expect(refused.single.level, ConfigIssueLevel.error);
      expect(refused.single.message, contains('HORIZON_ALLOW_SQLITE'));
      expect(
        HorizonConfig.check(
          embed,
          repo(const HorizonConfig(allowSqlite: true)),
        ),
        isEmpty,
      );
      expect(
        HorizonConfig.check(Env.fromMap({}), repo(const HorizonConfig())),
        isEmpty,
        reason: 'standalone horizon only warns when it starts',
      );
      expect(HorizonConfig.onSqliteFile(repo(const HorizonConfig())), isTrue);
      expect(
        HorizonConfig.onSqliteFile(repo(const HorizonConfig(), db: ':memory:')),
        isFalse,
      );
    });
  });
}
