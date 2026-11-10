import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:daravel_reverb/daravel_reverb.dart';
import 'package:daravel_test/daravel_test.dart';
import 'package:test/test.dart';

final String secret = 's' * 32;

Application appWith({List<Object> dashboard = const []}) =>
    Application.configure(
          basePath: Directory.systemTemp.createTempSync('reverb_setup_').path,
        )
        .withEnv({
          'APP_ENV': 'testing',
          'DB_DATABASE': ':memory:',
          'REVERB_APP_ID': '42',
          'REVERB_APP_KEY': 'key-a',
          'REVERB_APP_SECRET': secret,
        })
        .withLogLevel(LogLevel.critical)
        .withBroadcasting(authMiddleware: const [])
        .withReverb(dashboard: dashboard)
        .create();

void main() {
  test('no stats route without dashboard middleware', () async {
    final app = appWith();
    await app.boot();
    addTearDown(app.shutdown);
    expect((await TestClient(app).get('/reverb')).status, 404);
    // The HTTP application does not watch for reverb:restart.
    expect(app.container.resolved<ReverbRestartWatcher>(), isNull);
  });

  test('the stats route sits behind its middleware, without secrets', () async {
    final guarded = appWith(dashboard: [const _Refuse()]);
    await guarded.boot();
    addTearDown(guarded.shutdown);
    expect((await TestClient(guarded).get('/reverb')).status, 403);
    expect(
      guarded.router.routes.where((r) => r.path == '/reverb'),
      hasLength(1),
    );

    final stats = await guarded.run(() => reverbStats(guarded.container));
    expect(stats['provider'], 'config');
    expect((stats['apps']! as List).single, containsPair('key', 'key-a'));
    expect('$stats', isNot(contains(secret)));
  });
}

/// Stands in for `['auth', 'can:viewReverb']`: refuses everyone.
final class _Refuse implements Middleware {
  const _Refuse();

  @override
  Future<Response> handle(Request request, Next next) async =>
      Response(status: 403);
}
