@Tags(['security'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:daravel/daravel.dart';
import 'package:daravel/src/foundation/slashes.dart';
import 'package:test/test.dart';

import 'str_inflect_golden.dart';

/// Slashes are trimmed in one pass. `RegExp(r'^/+|/+$')` and
/// `RegExp(r'/+$')` took time quadratic in a run of slashes that does not
/// end the value, and request paths reach them: the label of every 404 and
/// 405, `Request.url`, the paginator's path, `DaravelUri.path`. The same
/// held for `Str.plural`/`singular` on a run of letters (`([A-Za-z]+)$`).
void main() {
  group('the same results as the regular expressions', () {
    final random = Random(20261113);
    String pick(String alphabet, int max) => String.fromCharCodes([
      for (var i = random.nextInt(max + 1); i > 0; i--)
        alphabet.codeUnitAt(random.nextInt(alphabet.length)),
    ]);

    test('trimSlashes and trimTrailingSlashes, 20 000 random values', () {
      final both = RegExp(r'^/+|/+$');
      final trailing = RegExp(r'/+$');
      for (var i = 0; i < 20000; i++) {
        final value = pick('//ab.', 12);
        expect(trimSlashes(value), value.replaceAll(both, ''), reason: value);
        expect(
          trimTrailingSlashes(value),
          value.replaceAll(trailing, ''),
          reason: value,
        );
      }
    });

    test('Str.plural and Str.singular: what the regular expression gave on '
        '300 random values', () {
      for (final (value, plural, singular) in strInflectGolden) {
        expect(Str.plural(value), plural, reason: value);
        expect(Str.singular(value), singular, reason: value);
      }
    });
  });

  // Three sizes, n, 8n and 64n: the step past allocation thresholds (8n to
  // 64n) is judged, about 8 linear and 64 quadratic; the limit of 32 sits
  // between. The first step is only shown.
  group('linear in the length', () {
    double ms(void Function() run) {
      run();
      var best = double.infinity;
      for (var i = 0; i < 3; i++) {
        final watch = Stopwatch()..start();
        run();
        final time = watch.elapsedMicroseconds / 1000;
        if (time < best) {
          best = time;
        }
      }
      return best;
    }

    for (final (label, run) in [
      ('trimSlashes', (int n) => trimSlashes('/x${'/' * n}y')),
      ('trimTrailingSlashes', (int n) => trimTrailingSlashes('x${'/' * n}y/')),
      ('Str.plural', (int n) => Str.plural('${'a' * n}1')),
    ]) {
      test(label, () {
        final small = ms(() => run(50000));
        final middle = ms(() => run(400000));
        final large = ms(() => run(3200000));
        final shown =
            '50 000: ${small.toStringAsFixed(2)} ms, 400 000: '
            '${middle.toStringAsFixed(2)} ms, 3 200 000: '
            '${large.toStringAsFixed(2)} ms';
        expect(large / middle, lessThan(32), reason: shown);
        // The regular expressions took hours on 3 200 000 characters.
        expect(large, lessThan(5000), reason: shown);
      });
    }
  });

  group('through a socket', () {
    late ServerEngine engine;

    setUp(() async {
      final app = Application.configure(basePath: Directory.systemTemp.path)
          .withEnv(const {'APP_ENV': 'testing', 'DB_DATABASE': ':memory:'})
          .withLogLevel(LogLevel.critical)
          .withRouting(
            web: (router) {
              router.get('/ok', (q) => 'ok');
              router.get('/url/{rest}', (q) => {'url': q.url.length});
            },
          )
          .create();
      await app.boot();
      addTearDown(app.shutdown);
      engine = ServerEngine(
        app,
        const ServeOptions(host: '127.0.0.1', port: 0, handleSignals: false),
        kernel: app.kernel,
        logger: Logger(handlers: [MemoryHandler()]),
      );
      await engine.start();
      addTearDown(engine.stop);
    });

    Future<(String, int)> get(String target) async {
      final watch = Stopwatch()..start();
      final socket = await Socket.connect('127.0.0.1', engine.port!);
      socket.add(
        latin1.encode(
          'GET $target HTTP/1.1\r\nHost: h\r\nAccept: application/json\r\n'
          'Connection: close\r\n\r\n',
        ),
      );
      await socket.flush();
      final reply = await utf8.decoder
          .bind(socket)
          .join()
          .timeout(const Duration(seconds: 30));
      socket.destroy();
      return (reply.split('\r\n').first, watch.elapsedMilliseconds);
    }

    // 32 000 slashes: 15 s and more before (seconds already at 16 000).
    test(
      'the 404 of a path with a long run of slashes answers at once',
      () async {
        final (status, ms) = await get('/x${'/' * 32000}y');
        expect(status, 'HTTP/1.1 404 Not Found');
        expect(ms, lessThan(2000), reason: '$ms ms');
      },
    );
  });
}
