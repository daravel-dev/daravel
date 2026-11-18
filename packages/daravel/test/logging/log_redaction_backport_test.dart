import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:daravel/daravel.dart';
import 'package:daravel_test/daravel_test.dart';
import 'package:test/test.dart';

/// Readiness errors stay out of the public body of `/up/ready`, and
/// redaction reaches every map (whatever its key type) and iterable, with
/// keys matched whatever their case and `-`/`_`; it never throws and
/// always ends.
void main() {
  group('/up/ready', () {
    Future<(TestResponse, MemoryHandler)> ready({required bool debug}) async {
      final app = Application.configure(basePath: Directory.systemTemp.path)
          .withEnv({
            'APP_ENV': 'testing',
            'APP_DEBUG': '$debug',
            'DB_DATABASE': ':memory:',
          })
          .withLogLevel(LogLevel.debug)
          .withRouting(web: (router) {})
          .withHealthChecks([
            CallbackHealthCheck(
              'redis',
              () => throw StateError(
                'Redis internal://:pass123@10.0.5.9:6379 refused connection',
              ),
            ),
          ])
          .create();
      await app.boot();
      addTearDown(app.shutdown);
      final logs = await app.run(() async => Log.spy());
      return (await TestClient(app).get('/up/ready'), logs);
    }

    test(
      'without APP_DEBUG: only names, ok and time; the error is logged',
      () async {
        final (response, logs) = await ready(debug: false);
        expect(response.status, 503);
        expect(response.body, isNot(contains('pass123')));
        expect(response.body, isNot(contains('10.0.5.9')));
        final checks = response.jsonMap['checks']! as Map<String, Object?>;
        expect(
          (checks['redis']! as Map<String, Object?>).keys,
          unorderedEquals(['ok', 'ms']),
        );
        expect(
          logs.matching(LogLevel.warning, 'Readiness check [redis] failed'),
          hasLength(1),
        );
      },
    );

    test('with APP_DEBUG: the error is in the body', () async {
      final (response, _) = await ready(debug: true);
      expect(response.body, contains('pass123'));
    });
  });

  group('redaction', () {
    final logger = Logger(handlers: const []);

    test('every map and iterable; keys whatever their case and -/_', () {
      final redacted = logger.redact({
        'dynamic': <dynamic, dynamic>{'password': 's1', 1: 'one'},
        'objects': <Object?, Object?>{'Authorization': 's2'},
        'set': {
          {'X-Api-Key': 's3'},
        },
        'nested': [
          [
            {'session-id': 's5', 'apiKey': 's6', 'private_key': 's7'},
          ],
        ],
        'creds': {'DSN': 's8', 'credentials': 's9', 'jwt': 's10'},
        // Nested in a context map, as a request's headers often are.
        'context': {
          'request': {'X-API-Key': 's11', 'Bearer': 's12'},
        },
      });
      final text = jsonEncode(redacted, toEncodable: (o) => '$o');
      for (final i in [1, 2, 3, 5, 6, 7, 8, 9, 10, 11, 12]) {
        expect(text, isNot(contains('"s$i"')), reason: 's$i');
      }
      expect(text, contains('"1":"one"'));
    });

    test('property: random structures never let a sensitive value out', () {
      final random = Random(41);
      const sensitive = [
        'password',
        'Authorization',
        'x-api-key',
        'API_KEY',
        'cookie',
        'Set-Cookie',
        'jwt',
        'secret',
      ];
      var secrets = 0;
      Object? build(int depth) {
        if (depth > 4 || random.nextInt(4) == 0) {
          return 'plain${random.nextInt(9)}';
        }
        Map<Object?, Object?> map() => {
          for (var i = 0; i < 1 + random.nextInt(3); i++)
            if (random.nextBool())
              sensitive[random.nextInt(sensitive.length)]: 'S3CR3T-${secrets++}'
            else
              'k$i': build(depth + 1),
        };
        return switch (random.nextInt(4)) {
          0 => map(),
          1 => <dynamic, dynamic>{...map()},
          2 => [for (var i = 0; i < 2; i++) build(depth + 1)],
          _ => {for (var i = 0; i < 2; i++) build(depth + 1)},
        };
      }

      for (var round = 0; round < 500; round++) {
        final redacted = logger.redact({'root': build(0)});
        final text = jsonEncode(redacted, toEncodable: (o) => '$o');
        expect(text, isNot(contains('S3CR3T')), reason: 'round $round');
      }
      expect(secrets, greaterThan(100));
    });

    test('a throwing iterable or key: the record is still written, the '
        'value marked', () {
      final memory = MemoryHandler();
      final logger = Logger(handlers: [memory]);
      Iterable<int> throwing() sync* {
        yield 1;
        throw StateError('lazy');
      }

      expect(
        () => logger.info('ctx', {
          'lazy': throwing(),
          'keys': {_ThrowingKey(): 'v', 'password': 's1'},
          'ok': 'kept',
        }),
        returnsNormally,
      );
      final context = memory.records.single.context;
      expect(context['lazy'], startsWith('[UNLOGGABLE: '));
      expect(context['keys'], {
        '[UNLOGGABLE: _ThrowingKey]': '[REDACTED]',
        'password': '[REDACTED]',
      });
      expect(context['ok'], 'kept');
    }, timeout: const Timeout(Duration(seconds: 10)));

    test('an endless iterable ends at the budget', () {
      Iterable<int> endless() sync* {
        for (var i = 0; ; i++) {
          yield i;
        }
      }

      final list = logger.redact({'n': endless()})['n']! as List<Object?>;
      expect(list.last, '[TRUNCATED]');
      expect(list.length, lessThanOrEqualTo(10001));
    }, timeout: const Timeout(Duration(seconds: 10)));

    test(
      'a structure holding itself twice ends at the budget, not 2^32 nodes',
      () {
        final a = <Object?>[];
        a
          ..add(a)
          ..add(a);
        final text = jsonEncode(logger.redact({'a': a}));
        expect(text, contains('[TRUNCATED]'));
        expect(text, contains('[DEPTH]'));
      },
      timeout: const Timeout(Duration(seconds: 10)),
    );
  });
}

final class _ThrowingKey {
  @override
  String toString() => throw StateError('no');
}
