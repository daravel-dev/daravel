import 'dart:io';

import 'package:args/command_runner.dart';
import 'package:daravel/daravel.dart';
import 'package:dartisan_cli/dartisan_cli.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// `cache:clear` keeps locks unless `--locks`; `cache:prune-expired`
/// deletes what the database store keeps after expiry (#167).
void main() {
  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('dartisan_cache_commands');
    File(p.join(root.path, 'pubspec.yaml')).writeAsStringSync('name: demo\n');
    Directory(p.join(root.path, 'bootstrap')).createSync();
  });
  tearDown(() {
    Clock.restore();
    root.deleteSync(recursive: true);
  });

  Application createApp() => Application.configure(basePath: root.path)
      .withEnv({
        'APP_ENV': 'testing',
        'DB_DATABASE': p.join(root.path, 'database.sqlite'),
        'CACHE_STORE': 'database',
      })
      .withMigrations(const [CreateCacheTable()])
      .create();

  Future<T> inApp<T>(Future<T> Function() body) async {
    final app = createApp();
    await app.boot();
    try {
      return await app.run(body);
    } finally {
      await app.shutdown();
    }
  }

  Future<int> run(List<String> args) async {
    final runner = CommandRunner<int>('dartisan', 'test')
      ..addCommand(CacheClearCommand(createApp))
      ..addCommand(CachePruneExpiredCommand(createApp));
    return await IOOverrides.runZoned<Future<int?>>(
          () => runner.run(args),
          getCurrentDirectory: () => root,
        ) ??
        0;
  }

  test('cache:clear keeps the locks unless --locks', () async {
    await inApp(() async {
      await App.make<Migrator>().run();
      await Cache.put('k', 1);
      expect(await Cache.lock('report', owner: 'a').acquire(), isTrue);
    });
    expect(await run(['cache:clear']), 0);
    await inApp(() async {
      expect(await Cache.get<int>('k'), isNull);
      expect(await Cache.lock('report').currentOwner(), 'a');
    });
    expect(await run(['cache:clear', '--locks']), 0);
    await inApp(() async {
      expect(await Cache.lock('report').currentOwner(), isNull);
    });
  });

  test('cache:prune-expired deletes expired rows and locks', () async {
    Clock.freeze();
    await inApp(() async {
      await App.make<Migrator>().run();
      await Cache.put('short', 1, ttl: const Duration(seconds: 1));
      await Cache.put('long', 1, ttl: const Duration(hours: 1));
      await Cache.lock('stale', ttl: const Duration(seconds: 1)).acquire();
    });
    Clock.travel(const Duration(seconds: 2));
    expect(await run(['cache:prune-expired', 'database']), 0);
    await inApp(() async {
      expect(await DB.table('cache').count(), 1);
      expect(await DB.table('cache_locks').count(), 0);
    });
  });
}
