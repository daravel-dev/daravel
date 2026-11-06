import 'dart:convert';
import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:daravel_reverb/daravel_reverb.dart';
import 'package:daravel_test/daravel_test.dart';
import 'package:test/test.dart';

final String secret = 's' * 32;

Application appWith(Map<String, String> env, {ReverbAppsFactory? apps}) {
  final builder =
      Application.configure(
            basePath: Directory.systemTemp.createTempSync('reverb_apps_').path,
          )
          .withEnv({'APP_ENV': 'testing', 'DB_DATABASE': ':memory:', ...env})
          .withLogLevel(LogLevel.critical)
          .withMigrations(const [CreateReverbAppsTable()])
          .withBroadcasting(authMiddleware: const []);
  return (apps == null ? builder.withReverb() : builder.withReverb(apps: apps))
      .create();
}

void main() {
  tearDown(travelBack);

  group('config', () {
    test('empty REVERB_APPS: the app of the settings alone', () async {
      final app = appWith({
        'REVERB_APP_ID': '42',
        'REVERB_APP_KEY': 'key-a',
        'REVERB_APP_SECRET': secret,
      });
      await app.boot();
      addTearDown(app.shutdown);
      final provider = ReverbApps.fromEnv(app.container);
      expect(provider, isA<SingleAppProvider>());
      expect((await provider.byKey('key-a'))?.id, '42');
    });

    test('two apps, with the settings app unless listed', () async {
      final listed = jsonEncode([
        {'app_id': '7', 'key': 'key-b', 'secret': secret},
        {'app_id': '8', 'key': 'key-c', 'secret': secret},
      ]);
      final app = appWith({
        'REVERB_APP_ID': '42',
        'REVERB_APP_KEY': 'key-a',
        'REVERB_APP_SECRET': secret,
        'REVERB_APPS': listed,
      });
      await app.boot();
      addTearDown(app.shutdown);
      final provider = ReverbApps.fromEnv(app.container) as ListAppProvider;
      expect(provider.apps.map((a) => a.id), ['42', '7', '8']);
      expect((provider.byKey('key-c'))?.id, '8');
      expect(provider.byId('9'), isNull);

      // Without REVERB_APP_*: only the list.
      final bare = appWith({'REVERB_APPS': listed});
      await bare.boot();
      addTearDown(bare.shutdown);
      final only = ReverbApps.fromEnv(bare.container) as ListAppProvider;
      expect(only.apps.map((a) => a.id), ['7', '8']);
    });
  });

  group('database', () {
    late Application app;
    late DatabaseAppProvider provider;

    setUp(() async {
      app = appWith({
        'REVERB_APPS_PROVIDER': 'database',
        'REVERB_APPS_CACHE_TTL': '60s',
        'REVERB_APP_ID': '42',
        'REVERB_APP_KEY': 'key-a',
        'REVERB_APP_SECRET': secret,
      });
      await app.boot();
      await app.run(() => App.make<Migrator>().run());
      await app.run(
        () => DB.table('reverb_apps').insert({
          'app_id': '7',
          'key': 'key-b',
          'secret': secret,
          'allowed_origins': jsonEncode(['b.example.com']),
          'max_connections': 3,
          'rate_limiting': jsonEncode({'enabled': true, 'max_attempts': 5}),
        }),
      );
      provider = ReverbApps.fromSource(app.container) as DatabaseAppProvider;
    });

    tearDown(() => app.shutdown());

    test('reads a row by key and by id; the settings app needs none', () async {
      final b = (await provider.byKey('key-b'))!;
      expect(b.id, '7');
      expect(b.allowedOrigins, ['b.example.com']);
      expect(b.maxConnections, 3);
      expect(b.rateLimiting?.maxAttempts, 5);
      expect((await provider.byId('7'))?.key, 'key-b');
      expect((await provider.byKey('key-a'))?.id, '42');
      expect(await provider.byKey('key-x'), isNull);
    });

    test('keeps what it read for the TTL, misses too', () async {
      freezeTime();
      expect(await provider.byKey('key-b'), isNotNull);
      expect(await provider.byKey('key-new'), isNull);
      await app.run(() async {
        await DB.table('reverb_apps').where('app_id', '7').delete();
        await DB.table('reverb_apps').insert({
          'app_id': '9',
          'key': 'key-new',
          'secret': secret,
        });
      });
      // Kept: no query per connection.
      expect(await provider.byKey('key-b'), isNotNull);
      expect(await provider.byKey('key-new'), isNull);
      travel(const Duration(seconds: 61));
      expect(await provider.byKey('key-b'), isNull);
      expect((await provider.byKey('key-new'))?.id, '9');
      // forget() reads again at once.
      await app.run(
        () => DB.table('reverb_apps').where('app_id', '9').delete(),
      );
      expect(await provider.byKey('key-new'), isNotNull);
      provider.forget();
      expect(await provider.byKey('key-new'), isNull);
    });
  });
}
