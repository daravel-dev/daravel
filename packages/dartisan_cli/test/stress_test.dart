import 'dart:convert';
import 'dart:io';

import 'package:dartisan_cli/dartisan_cli.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// A server shaped like a new Daravel project: the health check, ping,
/// token registration and `me`, a login limited to 5 attempts, and two
/// routes for `--path`: one that fails and one that works.
Future<HttpServer> fakeApp() async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  var logins = 0;
  server.listen((request) async {
    final response = request.response;
    final body = await utf8.decodeStream(request);
    void json(int status, Object data) {
      response
        ..statusCode = status
        ..headers.contentType = ContentType.json
        ..write(jsonEncode(data));
    }

    switch ((request.method, request.uri.path)) {
      case ('GET', '/up'):
        response.write('ok');
      case ('GET', '/api/ping'):
        json(200, {'message': 'pong'});
      case ('POST', '/api/auth/register'):
        expect(
          jsonDecode(body),
          containsPair('email', endsWith('@example.test')),
        );
        json(201, {'token': '1|secret-token-value', 'token_type': 'Bearer'});
      case ('GET', '/api/auth/me'):
        final auth = request.headers.value('authorization');
        json(auth == 'Bearer 1|secret-token-value' ? 200 : 401, {
          'data': <String, Object?>{},
        });
      case ('POST', '/api/auth/login'):
        json(++logins > 5 ? 429 : 422, {'message': 'no'});
      case ('GET', '/api/internal/orders'):
        json(200, {'data': <Object?>[]});
      case ('GET', '/api/internal/boom'):
        json(500, {'message': 'Server Error'});
      default:
        json(404, {'message': 'Not found'});
    }
    await response.close();
  });
  return server;
}

StressRound round(List<int> latenciesMs, Map<int, int> statuses, int ms) =>
    StressRound(
      elapsed: Duration(milliseconds: ms),
      latenciesUs: [for (final l in latenciesMs) l * 1000],
      statuses: statuses,
    );

void main() {
  test('statistics: throughput spread, quantiles, errors', () {
    const scenario = StressScenario(name: 'ping', description: '', path: '/');
    final result = StressResult(scenario, [
      round([for (var i = 1; i <= 100; i++) i], {200: 100}, 1000),
      round([for (var i = 1; i <= 100; i++) i], {200: 98, 500: 1, 0: 1}, 500),
    ]);
    expect(result.requests, 200);
    expect(result.rpsMean, 150);
    expect(result.rpsStdev, closeTo(70.71, .01));
    expect(result.quantileMs(.5), 50);
    expect(result.quantileMs(.95), 95);
    expect(result.quantileMs(1), 100);
    expect(result.serverErrors, 1);
    expect(result.connectionErrors, 1);
    expect(result.errors, 2);
    expect(result.toJson(public: true)['statuses'], {
      '2xx': 198,
      '5xx': 1,
      'no_response': 1,
    });
    expect(stressFailures([result], maxP95: 90, minRps: 200), [
      'ping: 1 server errors (5xx)',
      'ping: 1 requests without a response',
      'ping: p95 95.00 ms > 90.0 ms',
      'ping: 150 req/s < 200.0',
    ]);

    // The limited login answers 422 then 429 by design, slowly.
    const limited = StressScenario(
      name: 'rate_limit',
      description: '',
      path: '/',
      expected: {422, 429},
    );
    final login = StressResult(limited, [
      round([500, 600], {422: 1, 429: 1}, 1000),
    ]);
    expect(stressFailures([login], maxP95: 10, minRps: 1000), isEmpty);
    final wrong = StressResult(limited, [
      round([5, 6], {200: 2}, 1000),
    ]);
    expect(stressFailures([wrong]), [
      'rate_limit: 2 unexpected statuses (expected 422/429)',
    ]);
  });

  group('against a server', () {
    late HttpServer server;
    late Uri base;
    setUp(() async {
      server = await fakeApp();
      base = Uri.parse('http://127.0.0.1:${server.port}');
    });
    tearDown(() => server.close(force: true));

    test(
      'a round sends exactly its requests, on one or more isolates',
      () async {
        const scenario = StressScenario(
          name: 'ping',
          description: '',
          path: '/api/ping',
        );
        for (final isolates in [1, 3]) {
          final result = await runStressRound(
            base,
            scenario,
            requests: 101,
            concurrency: 7,
            isolates: isolates,
          );
          expect(result.requests, 101);
          expect(result.statuses, {200: 101});
          expect(result.rps, greaterThan(0));
        }
      },
    );

    test('discovery finds what the application has', () async {
      final (scenarios, notes) = await discoverScenarios(
        base,
        paths: ['/api/internal/orders'],
      );
      expect(
        [for (final s in scenarios) s.name],
        ['health', 'ping', 'not_found', 'auth_me', 'rate_limit', 'custom_1'],
      );
      expect(notes, isEmpty);
      final me = scenarios.firstWhere((s) => s.name == 'auth_me');
      expect(me.headers['authorization'], 'Bearer 1|secret-token-value');
    });

    test('the command: pass, fail, and a public report that hides the '
        'target', () async {
      final dir = Directory.systemTemp.createTempSync('stress_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final private = p.join(dir.path, 'stress.json');
      final public = p.join(dir.path, 'public', 'stress.json');
      Future<int?> stress(List<String> args) =>
          DartisanRunner(() => throw StateError('not booted')).run([
            'test:stress',
            '--url=$base',
            '--rounds=2',
            '--requests=30',
            '--concurrency=4',
            '--isolates=1',
            '--warmup=5',
            '--cooldown=0',
            ...args,
          ]);

      expect(
        await stress([
          '--path=/api/internal/orders',
          '--json=$private',
          '--export-public=$public',
        ]),
        0,
      );
      final report = File(private).readAsStringSync();
      expect(report, contains('${server.port}'));
      final shared = File(public).readAsStringSync();
      for (final secret in [
        '127.0.0.1',
        '${server.port}',
        'secret-token-value',
        'example.test',
        '/api/internal',
        'Bearer',
      ]) {
        expect(shared, isNot(contains(secret)), reason: secret);
      }
      final scenarios =
          (jsonDecode(shared) as Map<String, Object?>)['scenarios']!
              as List<Object?>;
      expect(scenarios, hasLength(6));
      expect(
        scenarios.last,
        isNot(contains('path')),
        reason: 'custom routes are not published',
      );

      expect(
        await stress(['--scenario=ping,custom_1', '--path=/api/internal/boom']),
        1,
        reason: 'a 5xx fails the run',
      );
      expect(await stress(['--scenario=ping', '--max-p95=0']), 1);
    });
  });
}
