import 'dart:convert';
import 'dart:io';
import 'dart:math';

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

  test('malformed bypass cookie behaves like no bypass cookie', () async {
    mode.activate(secret: 'preview-123');
    app = await boot();
    final logs = await app.run(() async => Log.spy());
    final normal = await app.handle(Request.fake(path: '/api/ping'));
    final normalLogs = [
      for (final r in logs.records) (r.level, r.message, '${r.error}'),
    ];
    logs.clear();
    final response = await app.handle(
      Request.fake(
        path: '/api/ping',
        headers: {'cookie': 'daravel_maintenance=%zz'},
      ),
    );
    expect(response.status, normal.status);
    expect(response.status, 503);
    expect(await response.bodyText(), await normal.bodyText());
    expect(
      response.headers.toSingleValueMap(),
      normal.headers.toSingleValueMap(),
    );
    expect([
      for (final r in logs.records) (r.level, r.message, '${r.error}'),
    ], normalLogs);
  });

  test('malformed percent encodings never grant a bypass', () async {
    mode.activate(secret: 'preview-123');
    app = await boot();
    for (var seed = 0; seed < 500; seed++) {
      final random = Random(seed);
      const digits = '0123456789abcdef';
      final prefix = List.generate(
        random.nextInt(8),
        (_) => digits[random.nextInt(digits.length)],
      ).join();
      final bad = random.nextBool()
          ? '%z${digits[random.nextInt(digits.length)]}'
          : '%';
      final request = Request.fake(
        headers: {'cookie': 'a=b; daravel_maintenance=$prefix$bad'},
      );
      expect(
        PreventRequestsDuringMaintenance.hasValidBypassCookie(
          request,
          'preview-123',
        ),
        isFalse,
        reason: 'seed $seed',
      );
    }
  });

  test('CI reports cookie parsing costs', () async {
    app = await boot();
    final cases = <String, String>{
      'long-value': 'daravel_maintenance=${'a' * (1024 * 1024)}%zz',
      'distinct-values':
          '${List.generate(10000, (i) => 'k$i=$i').join(';')}; daravel_maintenance=%zz',
      'many-items':
          '${List.filled(10000, 'a=b').join(';')}; daravel_maintenance=%zz',
    };
    for (final entry in cases.entries) {
      final request = Request.fake(headers: {'cookie': entry.value});
      final timer = Stopwatch()..start();
      for (var i = 0; i < 20; i++) {
        expect(
          PreventRequestsDuringMaintenance.hasValidBypassCookie(
            request,
            'secret',
          ),
          isFalse,
        );
      }
      timer.stop();
      print(
        'cookie ${entry.key}: ${entry.value.length} bytes, 20 runs, ${timer.elapsedMicroseconds} us',
      );
    }
  }, skip: Platform.environment['CI'] != 'true' ? 'CI timing only' : false);

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
