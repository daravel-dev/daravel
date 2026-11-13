import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:daravel/daravel.dart';
import 'package:daravel_test/daravel_test.dart';
import 'package:test/test.dart';

/// LG-1 (Reviewer RSEQ 41): readiness errors stay out of the public body,
/// redaction reaches every map, iterable and `Headers`, console lines
/// cannot be forged, an empty METRICS_TOKEN stops the boot, and a
/// Prometheus label escapes `\r`.
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

    test('every map, iterable and Headers; keys whatever their case and '
        '-/_', () {
      final redacted = logger.redact({
        'dynamic': <dynamic, dynamic>{'password': 's1', 1: 'one'},
        'objects': <Object?, Object?>{'Authorization': 's2'},
        'set': {
          {'X-Api-Key': 's3'},
        },
        'headers': Headers({'authorization': 'Bearer s4', 'accept': 'x'}),
        'nested': [
          [
            {'session-id': 's5', 'apiKey': 's6', 'private_key': 's7'},
          ],
        ],
        'creds': {'DSN': 's8', 'credentials': 's9', 'jwt': 's10'},
      });
      final text = jsonEncode(redacted, toEncodable: (o) => '$o');
      for (var i = 1; i <= 10; i++) {
        expect(text, isNot(contains('"s$i"')), reason: 's$i');
        expect(text, isNot(contains('Bearer s4')));
      }
      expect(text, contains('"accept":"x"'));
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
        return switch (random.nextInt(5)) {
          0 => map(),
          1 => <dynamic, dynamic>{...map()},
          2 => [for (var i = 0; i < 2; i++) build(depth + 1)],
          3 => {for (var i = 0; i < 2; i++) build(depth + 1)},
          _ => Headers({
            'authorization': 'S3CR3T-${secrets++}',
            'accept': 'text/html',
          }),
        };
      }

      for (var round = 0; round < 500; round++) {
        final redacted = logger.redact({'root': build(0)});
        final text = jsonEncode(redacted, toEncodable: (o) => '$o');
        expect(text, isNot(contains('S3CR3T')), reason: 'round $round');
      }
      expect(secrets, greaterThan(100));
    });

    test('a throwing iterable, toLogValue() or key: the record is still '
        'written, the value marked', () {
      final memory = MemoryHandler();
      final logger = Logger(handlers: [memory]);
      Iterable<int> throwing() sync* {
        yield 1;
        throw StateError('lazy');
      }

      expect(
        () => logger.info('ctx', {
          'lazy': throwing(),
          'loggable': _ThrowingLoggable(),
          'keys': {_ThrowingKey(): 'v', 'password': 's1'},
          'ok': 'kept',
        }),
        returnsNormally,
      );
      final context = memory.records.single.context;
      expect(context['lazy'], startsWith('[UNLOGGABLE: '));
      expect(context['loggable'], '[UNLOGGABLE: _ThrowingLoggable]');
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

  test('DEL, C1 and the Unicode line separators are escaped in the console '
      'message, error and context, and in JSON lines', () {
    final unsafe = [
      0x7f,
      0x85,
      0x9b,
      0x2028,
      0x2029,
    ].map(String.fromCharCode).join();
    final record = LogRecord(
      time: DateTime.utc(2026),
      level: LogLevel.error,
      message: 'm$unsafe',
      channel: 'app',
      context: {'v': 'c$unsafe'},
      error: StateError('e$unsafe'),
    );
    final err = StringBuffer();
    ConsoleHandler(out: StringBuffer(), err: err).handle(record);
    final json = StringBuffer();
    JsonHandler(json).handle(record);
    final unsafeChar = RegExp(
      '[${[0x7f, 0x85, 0x9b, 0x2028, 0x2029].map(String.fromCharCode).join()}]',
    );
    for (final (name, text) in [
      ('console', err.toString()),
      ('json', json.toString()),
    ]) {
      expect(text, isNot(matches(unsafeChar)), reason: name);
    }
    // Built in code: a literal backslash-u escape can be rewritten into the
    // character by the tools that edit this file.
    final separators = [
      0x2028,
      0x2029,
    ].map((c) => '${String.fromCharCode(92)}u${c.toRadixString(16)}').join();
    expect(err.toString(), contains(r'm\x7f\x85\x9b' + separators));
    expect(err.toString(), contains(r'e\x7f\x85\x9b' + separators));
    expect(err.toString(), contains(r'c\u007f\u0085\u009b' + separators));
    final decoded = jsonDecode(json.toString()) as Map<String, Object?>;
    expect(decoded['message'], 'm$unsafe', reason: 'valid JSON, same text');
  });

  test('a console line cannot be forged: control characters escaped, the '
      'stack trace on its own lines', () {
    final out = StringBuffer();
    final err = StringBuffer();
    final handler = ConsoleHandler(out: out, err: err);
    handler.handle(
      LogRecord(
        time: DateTime.utc(2026),
        level: LogLevel.info,
        message: 'route /a\n2026-01-01T00:00:00.000Z [ERROR] forged\r\x1b[31m',
        channel: 'app',
        context: const {},
      ),
    );
    handler.handle(
      LogRecord(
        time: DateTime.utc(2026),
        level: LogLevel.error,
        message: 'failed',
        channel: 'app',
        context: const {},
        error: StateError('bad\nline'),
        stackTrace: StackTrace.fromString('#0 a\n#1 b'),
      ),
    );
    final info = out.toString().trimRight();
    expect(info.split('\n'), hasLength(1), reason: info);
    expect(info, contains(r'\n'));
    expect(info, contains(r'\x1b'));
    expect(info, isNot(contains('\x1b')));
    final error = err.toString();
    expect(error, contains(r'bad\nline'));
    expect(error, contains('#0 a\n#1 b'), reason: 'the stack stays');
  });

  test('an empty METRICS_TOKEN stops the boot', () async {
    for (final token in ['', '   ']) {
      final app = Application.configure(basePath: Directory.systemTemp.path)
          .withEnv({
            'APP_ENV': 'testing',
            'DB_DATABASE': ':memory:',
            'METRICS_ENABLED': 'true',
            'METRICS_TOKEN': token,
          })
          .withLogLevel(LogLevel.critical)
          .create();
      await expectLater(
        app.boot(),
        throwsA(isA<ConfigException>()),
        reason: '"$token"',
      );
    }
  });

  test(r'a Prometheus label escapes \r', () {
    final registry = MetricsRegistry();
    registry.counter('hits_total', 'Hits.').inc({'path': 'a\rb'});
    final text = registry.render();
    expect(text, contains(r'path="a\rb"'));
    expect(text, isNot(contains('a\rb')));
  });
}

final class _ThrowingLoggable implements Loggable {
  @override
  Object? toLogValue() => throw StateError('no');
}

final class _ThrowingKey {
  @override
  String toString() => throw StateError('no');
}
