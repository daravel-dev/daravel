import 'dart:convert';

import 'package:daravel/daravel.dart';
import 'package:daravel_horizon/daravel_horizon.dart';
import 'package:daravel_test/daravel_test.dart';
import 'package:test/test.dart';

import '../bootstrap/app.dart';

void main() {
  late Application app;
  late TestClient client;

  Future<void> boot([Map<String, String> env = const {}]) async {
    app = createApp(
      env: {
        'APP_ENV': 'testing',
        'DB_DATABASE': ':memory:',
        'QUEUE_CONNECTION': 'database',
        'HORIZON_ALLOW_SQLITE': 'true',
        'LOG_LEVEL': 'emergency',
        ...env,
      },
    );
    await app.boot();
    await app.run(() => App.make<Migrator>().run());
    client = TestClient(app);
  }

  tearDown(() => app.shutdown());

  test('dispatched jobs wait on their queues and show as pending', () async {
    await boot();
    final dispatched = await client.post('/demo/dispatch?count=10');
    expect(dispatched.jsonMap['dispatched'], 10);
    expect(await app.run(() => Queue.size('default')), 11);
    expect(await app.run(() => Queue.size('reports')), 2);
    final pending =
        (await client.get('/horizon/api/jobs/pending')).jsonMap['jobs']!
            as List<Object?>;
    expect(pending, hasLength(13));
  });

  test('the dashboard reads what the workers record', () async {
    await boot();
    await app.run(
      () => App.make<CoordinatorChannel>().call('horizon', 'record', {
        'job': jsonEncode(
          RecordedJob(
            uuid: 'demo-1',
            name: 'quick',
            queue: 'default',
            status: 'completed',
            at: Clock.now().millisecondsSinceEpoch,
            durationMs: 3,
          ).toJson(),
        ),
      }),
    );
    final completed =
        (await client.get('/horizon/api/jobs/completed')).jsonMap['jobs']!
            as List<Object?>;
    expect((completed.single! as Map)['uuid'], 'demo-1');
    final stats = (await client.get('/horizon/api/stats')).jsonMap;
    expect((stats['wait']! as Map).keys, [
      'database:default',
      'database:reports',
    ]);
    expect((await client.get('/horizon')).status, 200);
  });

  test('outside local and testing the dashboard needs middleware', () async {
    await boot({
      'APP_ENV': 'production',
      'APP_KEY': 'base64:${base64.encode(List.filled(32, 3))}',
    });
    expect((await client.get('/horizon')).status, 403);
    expect((await client.get('/horizon/api/stats')).status, 403);
  });
}
