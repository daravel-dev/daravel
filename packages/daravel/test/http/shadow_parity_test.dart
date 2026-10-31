import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

void main() {
  group('JsonStructuralDiffer', () {
    List<String> diff(
      Object? ours,
      Object? theirs, {
      Set<String> ignore = const {},
    }) => [
      for (final drift in JsonStructuralDiffer(
        ignoreKeys: ignore,
      ).compare(ours, theirs))
        '${drift.kind}:${drift.path}',
    ];

    test('the same shape with other values is no drift', () {
      expect(diff({'a': 1, 'b': 'x'}, {'a': 2, 'b': 'y'}), isEmpty);
    });

    test('missing and extra keys', () {
      expect(diff({'a': 1, 'b': 2}, {'a': 1, 'c': 3}), [
        'missing_key:c',
        'extra_key:b',
      ]);
    });

    test('types, as a client tells them', () {
      expect(diff({'a': 1}, {'a': '1'}), ['type:a']);
      expect(diff({'a': true}, {'a': 1}), ['type:a']);
      expect(diff({'a': null}, {'a': 1}), ['type:a']);
      expect(diff({'a': 1}, {'a': 1.5}), ['type:a']);
      expect(diff({'a': <String, Object?>{}}, {'a': <Object?>[]}), ['type:a']);
    });

    test('list lengths and items', () {
      expect(
        diff(
          [
            {'a': 1},
            {'b': 1},
          ],
          [
            {'a': 1},
          ],
        ),
        ['length:'],
      );
      expect(
        diff(
          {
            'data': [
              {'id': 1},
            ],
          },
          {
            'data': [
              {'id': '1'},
            ],
          },
        ),
        ['type:data.0.id'],
      );
    });

    test('ignored paths, with * for an index', () {
      expect(
        diff(
          {
            'meta': {'took': 1},
            'data': [
              {'at': 1},
            ],
          },
          {
            'meta': {'took': 'x', 'other': 1},
            'data': [
              {'at': '2'},
            ],
          },
          ignore: {'meta', 'data.*.at'},
        ),
        isEmpty,
      );
    });

    test('a list of 100 renamed keys stops at the limit', () {
      final ours = [
        for (var i = 0; i < 100; i++) {'a': 1},
      ];
      final theirs = [
        for (var i = 0; i < 100; i++) {'b': 1},
      ];
      expect(JsonStructuralDiffer().compare(ours, theirs), hasLength(5));
    });

    test('a drift holds no value', () {
      final drift = JsonStructuralDiffer()
          .compare({'token': 'abc'}, {'token': 123})
          .single;
      expect(jsonEncode(drift.toJson()), isNot(contains('abc')));
      expect(jsonEncode(drift.toJson()), isNot(contains('123')));
    });
  });

  group('replay', () {
    late HttpServer upstream;
    late Directory base;
    late List<HttpRequest> seen;
    late List<ShadowParityDrift> drifts;
    late Application app;
    var answer = '{"id":1}';
    var status = 200;
    var type = 'application/json';

    Future<void> boot({
      double? sampleRate = 1,
      int? maxConcurrency,
      Set<String>? ignoreKeys,
      List<String> except = const [],
      Map<String, String> env = const {},
    }) async {
      app = Application.configure(basePath: base.path)
          .withEnv({'APP_ENV': 'testing', 'DB_DATABASE': ':memory:', ...env})
          .withLogLevel(LogLevel.critical)
          .withUpstream(
            url: 'http://127.0.0.1:${upstream.port}',
            shadowSampleRate: sampleRate,
            shadowMaxConcurrency: maxConcurrency,
            shadowIgnoreKeys: ignoreKeys,
            shadowExcept: except,
          )
          .withEvents((events) {
            events.listen<ShadowParityDrift>(drifts.add);
          })
          .withRouting(
            web: (router) {
              router
                ..get('/thing', (Request r) => {'id': 1})
                ..post('/thing', (Request r) => {'id': 1})
                ..get('/stream', (Request r) {
                  return Response.stream(
                    Stream.value(utf8.encode('{}')),
                    contentType: 'application/json',
                  );
                })
                ..get('/secret', (Request r) => {'id': 1});
            },
          )
          .create();
      await app.boot();
      addTearDown(app.shutdown);
    }

    /// Answers [request], then does what `terminate` does.
    Future<Response> send(Request request) async {
      final response = await app.handle(request);
      for (final callback in request.takeDeferred()) {
        await callback();
      }
      await pumpEventQueue();
      return response;
    }

    setUp(() async {
      answer = '{"id":1}';
      status = 200;
      type = 'application/json';
      seen = [];
      drifts = [];
      base = Directory.systemTemp.createTempSync('daravel_shadow');
      upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      upstream.listen((request) async {
        seen.add(request);
        request.response
          ..statusCode = status
          ..headers.set('content-type', type)
          ..write(answer);
        await request.response.close();
      });
    });

    tearDown(() async {
      await upstream.close(force: true);
      base.deleteSync(recursive: true);
    });

    test('the same answer is quiet', () async {
      await boot();
      await send(Request.fake(path: '/thing'));
      expect(seen, hasLength(1));
      expect(seen.single.headers.value('x-daravel-shadow'), '1');
      expect(drifts, isEmpty);
    });

    test('the client gets its response before any replay', () async {
      await boot();
      final request = Request.fake(path: '/thing');
      final response = await app.handle(request);
      expect(response.status, 200);
      expect(seen, isEmpty);
      expect(request.takeDeferred(), hasLength(1));
    });

    test('a different shape is an event', () async {
      answer = '{"id":"1","name":"x"}';
      await boot();
      await send(Request.fake(path: '/thing'));
      expect(drifts.single.path, '/thing');
      expect(
        [for (final d in drifts.single.drifts) d.kind],
        ['type', 'missing_key'],
      );
    });

    test('status and content type', () async {
      status = 500;
      type = 'text/html';
      answer = '<h1>';
      await boot();
      await send(Request.fake(path: '/thing'));
      expect(
        [for (final d in drifts.single.drifts) d.kind],
        ['status', 'content_type'],
      );
    });

    test('invalid JSON', () async {
      answer = '{oops';
      await boot();
      await send(Request.fake(path: '/thing'));
      expect(drifts.single.drifts.single.kind, 'invalid_json');
    });

    test('ignored keys', () async {
      answer = '{"id":"1"}';
      await boot(ignoreKeys: {'id'});
      await send(Request.fake(path: '/thing'));
      expect(drifts, isEmpty);
    });

    test('off by default, and rate 0 replays nothing', () async {
      await boot(sampleRate: null);
      await send(Request.fake(path: '/thing'));
      expect(seen, isEmpty);
    });

    test('the rate comes from the environment too', () async {
      await boot(
        sampleRate: null,
        env: {
          'UPSTREAM_SHADOW_SAMPLE': '1',
          'UPSTREAM_SHADOW_IGNORE_KEYS': 'id, other',
        },
      );
      answer = '{"id":"1"}';
      await send(Request.fake(path: '/thing'));
      expect(seen, hasLength(1));
      expect(drifts, isEmpty);
    });

    test('a rate outside 0 to 1 stops the boot', () async {
      app = Application.configure(basePath: base.path)
          .withEnv({'APP_ENV': 'testing', 'DB_DATABASE': ':memory:'})
          .withLogLevel(LogLevel.critical)
          .withUpstream(url: 'http://127.0.0.1:1', shadowSampleRate: 2)
          .create();
      await expectLater(app.boot(), throwsA(isA<ConfigException>()));
    });

    test('only what is safe to repeat', () async {
      await boot();
      await send(Request.fake(method: 'POST', path: '/thing', json: const {}));
      expect(seen, isEmpty);
    });

    test('a replay is never replayed', () async {
      await boot();
      await send(
        Request.fake(path: '/thing', headers: {'x-daravel-shadow': '1'}),
      );
      expect(seen, isEmpty);
    });

    test('except keeps paths out', () async {
      await boot(except: ['/secret']);
      await send(Request.fake(path: '/secret'));
      expect(seen, isEmpty);
    });

    test('a proxied request is not compared with itself', () async {
      await boot();
      await send(Request.fake(path: '/not-migrated'));
      expect(seen, hasLength(1), reason: 'the forward, and no replay');
      expect(seen.single.headers.value('x-daravel-shadow'), isNull);
    });

    test('a streamed answer is left alone', () async {
      await boot();
      await send(Request.fake(path: '/stream'));
      expect(seen, isEmpty);
    });

    test('a full semaphore drops the sample', () async {
      final release = Completer<void>();
      await upstream.close(force: true);
      upstream = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      upstream.listen((request) async {
        seen.add(request);
        await release.future;
        request.response.write('{"id":1}');
        await request.response.close();
      });
      await boot(maxConcurrency: 1);
      final first = Request.fake(path: '/thing');
      final second = Request.fake(path: '/thing');
      await app.handle(first);
      await app.handle(second);
      final running = first.takeDeferred().single();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await second.takeDeferred().single();
      expect(seen, hasLength(1));
      release.complete();
      await running;
    });

    test('an upstream that is down is no drift', () async {
      await boot();
      await upstream.close(force: true);
      await send(Request.fake(path: '/thing'));
      expect(drifts, isEmpty);
    });

    test('credentials go along', () async {
      await boot();
      await send(
        Request.fake(path: '/thing', headers: {'authorization': 'Bearer x'}),
      );
      expect(seen.single.headers.value('authorization'), 'Bearer x');
    });
  });
}
