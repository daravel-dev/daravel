// #164: retry backoff, jitter, ready-made predicates and Retry-After.
import 'dart:io';
import 'dart:math';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

/// A Random whose nextDouble returns the given values in turn.
final class _Fixed implements Random {
  _Fixed(this.values);
  final List<double> values;
  var _i = 0;
  @override
  double nextDouble() => values[_i++ % values.length];
  @override
  int nextInt(int max) => 0;
  @override
  bool nextBool() => false;
}

void main() {
  late HttpServer server;
  late List<(int, Map<String, String>)> script;
  late int hits;
  late List<Duration> waits;

  setUp(() async {
    hits = 0;
    waits = [];
    script = [];
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final (status, headers) = hits < script.length
          ? script[hits]
          : (200, const <String, String>{});
      hits++;
      request.response.statusCode = status;
      headers.forEach(request.response.headers.set);
      await request.response.close();
    });
  });

  tearDown(() => server.close(force: true));

  String url() => 'http://127.0.0.1:${server.port}/';

  HttpClientFactory factory({List<double> random = const [0.5]}) =>
      HttpClientFactory(
        random: _Fixed(random),
        sleep: (wait) async => waits.add(wait),
      );

  List<(int, Map<String, String>)> statuses(List<int> codes) => [
    for (final code in codes) (code, const <String, String>{}),
  ];

  test('exponential backoff waits 100, 200, 400 ms, capped at max', () async {
    script = statuses([500, 500, 500, 500]);
    final response = await factory()
        .request()
        .retry(
          5,
          backoff: Http.exponentialBackoff(
            max: const Duration(milliseconds: 300),
          ),
        )
        .get(url());
    expect(response.status, 200);
    expect(waits, const [
      Duration(milliseconds: 100),
      Duration(milliseconds: 200),
      Duration(milliseconds: 300),
      Duration(milliseconds: 300),
    ]);
  });

  test('backoffSequence keeps its last wait once it runs out', () async {
    script = statuses([500, 500, 500]);
    await factory()
        .request()
        .retry(
          4,
          backoff: Http.backoffSequence(const [
            Duration(milliseconds: 10),
            Duration(milliseconds: 50),
          ]),
        )
        .get(url());
    expect(waits, const [
      Duration(milliseconds: 10),
      Duration(milliseconds: 50),
      Duration(milliseconds: 50),
    ]);
  });

  test('jitter spreads each wait within ±jitter', () async {
    script = statuses([500, 500, 500]);
    // nextDouble 0 → ×0.8, 1 → ×1.2, 0.5 → ×1.0 with jitter 0.2.
    await factory(random: const [0, 1, 0.5])
        .request()
        .retry(4, delay: const Duration(milliseconds: 100), jitter: 0.2)
        .get(url());
    expect(waits, const [
      Duration(milliseconds: 80),
      Duration(milliseconds: 120),
      Duration(milliseconds: 100),
    ]);
    expect(
      () => factory().request().retry(2, jitter: 1.5),
      throwsArgumentError,
    );
  });

  test('a 404 is retried by default (Laravel), not with '
      'retryOnConnectionOr5xx', () async {
    script = statuses([404, 404]);
    final retried = await factory().request().retry(2).get(url());
    expect((retried.status, hits), (404, 2), reason: 'both tries made');
    hits = 0;
    script = statuses([404, 404]);
    final kept = await factory()
        .request()
        .retry(3, when: Http.retryOnConnectionOr5xx)
        .get(url());
    expect((kept.status, hits), (404, 1));
    hits = 0;
    script = statuses([429, 503]);
    final throttled = await factory()
        .request()
        .retry(3, when: Http.retryOnConnectionOr5xx)
        .get(url());
    expect((throttled.status, hits), (200, 3));
  });

  test('retryOnConnectionOnly retries a refused connection, not a 500', () {
    expect(Http.retryOnConnectionOnly(null, StateError('down')), isTrue);
    expect(Http.retryOnConnectionOnly(ClientResponse(500, ''), null), isFalse);
    expect(Http.retryOnConnectionOr5xx(ClientResponse(422, ''), null), isFalse);
  });

  test('Retry-After is honored on 429/503 when asked, at most '
      'maxRetryAfter', () async {
    script = [
      (429, const {'retry-after': '2'}),
      (503, const {'retry-after': '120'}),
      (500, const {'retry-after': '7'}),
    ];
    await factory()
        .request()
        .retry(
          4,
          delay: const Duration(milliseconds: 100),
          honorRetryAfter: true,
          maxRetryAfter: const Duration(seconds: 30),
        )
        .get(url());
    expect(waits, const [
      Duration(seconds: 2),
      Duration(seconds: 30),
      Duration(milliseconds: 100), // a 500 keeps the delay
    ]);
  });

  test('without the new options the waits are as before', () async {
    script = [
      (429, const {'retry-after': '2'}),
      (500, const <String, String>{}),
    ];
    await factory()
        .request()
        .retry(3, delay: const Duration(milliseconds: 100))
        .get(url());
    expect(waits, const [
      Duration(milliseconds: 100),
      Duration(milliseconds: 100),
    ]);
    waits.clear();
    script = statuses([500]);
    await factory().request().retry(2, delay: Duration.zero).get(url());
    expect(waits, isEmpty, reason: 'no wait at all for a zero delay');
  });
}
