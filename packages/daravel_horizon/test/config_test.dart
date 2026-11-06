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

  Future<List<ConfigIssue>> issues(HorizonConfig horizon) async {
    final config = ConfigRepository()
      ..register<HorizonConfig>(horizon)
      ..register<QueueConfig>(const QueueConfig(defaultConnection: 'database'));
    return HorizonConfig.check(Env.fromMap({}), config).toList();
  }

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
