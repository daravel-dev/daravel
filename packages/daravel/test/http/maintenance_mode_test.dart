import 'dart:convert';
import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

void main() {
  late Directory base;
  late MaintenanceMode mode;
  late Application app;

  Future<Application> boot() async {
    final created = Application.configure(basePath: base.path)
        .withEnv(const {'APP_ENV': 'testing', 'DB_DATABASE': ':memory:'})
        .withRouting(
          apiPrefix: '/api',
          health: '/up',
          api: (r) => r.get('/ping', (_) => {'ok': true}),
        )
        .create();
    await created.boot();
    return created;
  }

  setUp(() {
    base = Directory.systemTemp.createTempSync('daravel_down');
    mode = MaintenanceMode.at(base.path);
  });
  tearDown(() async {
    await app.shutdown();
    Clock.restore();
    base.deleteSync(recursive: true);
  });

  test('a live application is unaffected', () async {
    app = await boot();
    expect((await app.handle(Request.fake(path: '/api/ping'))).status, 200);
  });

  test('down answers 503 with Retry-After; health and except pass', () async {
    mode.activate(retry: 60, refresh: 15, except: ['/api/status']);
    app = await boot();
    final response = await app.handle(Request.fake(path: '/api/ping'));
    expect(response.status, 503);
    expect(response.headers.first('retry-after'), '60');
    expect(response.headers.first('refresh'), '15');
    expect(jsonDecode(await response.bodyText()), {
      'message': 'Service Unavailable',
    });
    expect((await app.handle(Request.fake(path: '/up'))).status, 200);
    expect((await app.handle(Request.fake(path: '/up/ready'))).status, 200);
    expect(
      (await app.handle(Request.fake(path: '/api/status'))).status,
      isNot(503),
    );
  });

  test('the secret path sets a bypass cookie that lets requests in', () async {
    mode.activate(secret: 'preview-123');
    app = await boot();
    final bypass = await app.handle(Request.fake(path: '/preview-123'));
    expect(bypass.status, 302);
    expect(bypass.headers.first('location'), '/');
    final cookie = bypass.headers.first('set-cookie')!;
    expect(cookie, startsWith('daravel_maintenance='));
    expect(cookie, contains('HttpOnly'));
    final pair = cookie.split(';').first;

    final allowed = await app.handle(
      Request.fake(path: '/api/ping', headers: {'cookie': 'a=b; $pair'}),
    );
    expect(allowed.status, 200);

    final forged = await app.handle(
      Request.fake(
        path: '/api/ping',
        headers: {
          'cookie':
              'daravel_maintenance=${base64.encode(utf8.encode('{"expires_at":9999999999,"mac":"x"}'))}',
        },
      ),
    );
    expect(forged.status, 503);

    Clock.travel(const Duration(hours: 13));
    final expired = await app.handle(
      Request.fake(path: '/api/ping', headers: {'cookie': pair}),
    );
    expect(expired.status, 503, reason: 'the cookie lasts 12 hours');
  });

  test('up is noticed after the check interval', () async {
    app = await boot();
    final middleware = PreventRequestsDuringMaintenance(
      mode,
      checkInterval: Duration.zero,
    );
    Future<Response> send() => middleware.handle(
      Request.fake(path: '/x'),
      (_) async => Response.text('ok'),
    );
    expect((await send()).status, 200);
    mode.activate();
    await expectLater(send(), throwsA(isA<HttpException>()));
    expect(mode.deactivate(), isTrue);
    expect((await send()).status, 200);
    expect(mode.deactivate(), isFalse);
  });

  test('the down file has the shape Laravel writes', () async {
    mode.activate(secret: 's', retry: 5);
    expect(jsonDecode(File(mode.path).readAsStringSync()), {
      'except': <Object?>[],
      'redirect': null,
      'retry': 5,
      'refresh': null,
      'secret': 's',
      'status': 503,
      'template': null,
    });
    app = await boot();
  });
}
