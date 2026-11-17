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

  test('check: QUEUE_RETRY_AFTER leaving a job under a second before the '
      'kill is an error; the database queue counts a second less', () {
    List<ConfigIssue> of(String connection, Duration retryAfter) {
      final config = ConfigRepository()
        ..register<HorizonConfig>(const HorizonConfig())
        ..register<QueueConfig>(
          QueueConfig(defaultConnection: connection, retryAfter: retryAfter),
        );
      return HorizonConfig.retryAfterIssues(config);
    }

    // Database: whole seconds, so 3 s leaves 3 - 1 - 1 (margin) = 1 s.
    expect(of('database', const Duration(seconds: 3)), isEmpty);
    final two = of('database', const Duration(seconds: 2));
    expect(two.single.level, ConfigIssueLevel.error);
    expect(
      two.single.message,
      allOf(
        contains('QUEUE_RETRY_AFTER=2 leaves Horizon 0 ms'),
        contains('whole seconds'),
        contains('Set it to at least 3.'),
      ),
    );
    // Redis: milliseconds, so 2 s leaves 1 s.
    expect(of('redis', const Duration(seconds: 2)), isEmpty);
    expect(
      of('redis', const Duration(milliseconds: 1500)).single.message,
      allOf(contains('leaves Horizon 500 ms'), contains('at least 2.')),
    );
    // A queue that does not reserve is not checked.
    expect(of('sync', Duration.zero), isEmpty);
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

  group('the lease of an idle worker', () {
    const ms = Duration(milliseconds: 1);

    test('four heartbeats, and on a SQLite file busy_timeout + 2 heartbeats '
        'when longer', () {
      // heartbeat -> busy_timeout (null: not a SQLite file) -> lease.
      final table = <(int, int?, int)>[
        (250, null, 1000),
        (250, 0, 1000),
        (250, 1000, 1500),
        (250, 5000, 5500),
        (250, 30000, 30500),
        (1000, null, 4000),
        (1000, 0, 4000),
        (1000, 1000, 4000),
        (1000, 5000, 7000),
        (1000, 30000, 32000),
        (5000, null, 20000),
        (5000, 0, 20000),
        (5000, 1000, 20000),
        (5000, 5000, 20000),
        (5000, 30000, 40000),
      ];
      for (final (beat, busy, lease) in table) {
        expect(
          HorizonConfig.idleLease(
            ms * beat,
            sqliteBusyTimeout: busy == null ? null : ms * busy,
          ),
          ms * lease,
          reason: 'heartbeat $beat ms, busy_timeout $busy ms',
        );
      }
    });

    ConfigRepository repo(
      String driver, {
      String queue = 'database',
      Map<String, Object?> options = const {},
    }) => ConfigRepository()
      ..register<HorizonConfig>(const HorizonConfig())
      ..register<QueueConfig>(QueueConfig(defaultConnection: queue))
      ..register<DatabaseConfig>(
        DatabaseConfig(
          defaultConnection: 'main',
          connections: {
            'main': ConnectionConfig(
              driver: driver,
              database: 'app.sqlite',
              options: options,
            ),
          },
        ),
      );

    test("the SQLite file's busy_timeout: 5 s unset, as set, 0 as 0", () {
      expect(
        HorizonConfig.sqliteBusyTimeout(repo('sqlite')),
        const Duration(seconds: 5),
      );
      expect(
        HorizonConfig.sqliteBusyTimeout(
          repo('sqlite', options: {'busy_timeout': 30000}),
        ),
        const Duration(seconds: 30),
      );
      expect(
        HorizonConfig.sqliteBusyTimeout(
          repo('sqlite', options: {'busy_timeout': '0'}),
        ),
        Duration.zero,
      );
    });

    test('other queues keep four heartbeats', () {
      for (final driver in ['pgsql', 'mysql', 'mariadb']) {
        expect(
          HorizonConfig.sqliteBusyTimeout(repo(driver)),
          isNull,
          reason: driver,
        );
      }
      expect(
        HorizonConfig.sqliteBusyTimeout(repo('sqlite', queue: 'redis')),
        isNull,
        reason: 'redis queue beside a SQLite database',
      );
    });

    test('a late round is deferred at most three times in a row; an on-time '
        'one is never', () {
      const beat = Duration(milliseconds: 500);
      bool defer(Duration late, int deferred) => HorizonConfig.deferLeaseRound(
        late: late,
        deferred: deferred,
        heartbeat: beat,
      );
      expect(defer(const Duration(milliseconds: 250), 0), isFalse);
      expect(defer(const Duration(milliseconds: 251), 0), isTrue);
      // A master late on every round: three deferred, the fourth kills.
      var deferred = 0;
      final decisions = <bool>[];
      for (var round = 0; round < 6; round++) {
        final d = defer(const Duration(seconds: 3), deferred);
        decisions.add(d);
        if (d) {
          deferred++;
        }
      }
      expect(decisions, [true, true, true, false, false, false]);
      expect(HorizonConfig.maxDeferredLeaseRounds, 3);
    });

    test('the SQLite warning says the lease it computes', () {
      expect(
        HorizonConfig.sqliteLeaseNote(
          const Duration(seconds: 1),
          const Duration(seconds: 5),
        ),
        'An idle worker is given busy_timeout (5000 ms) plus two '
        'heartbeats, 7000 ms, before it counts as gone.',
      );
    });
  });
}
