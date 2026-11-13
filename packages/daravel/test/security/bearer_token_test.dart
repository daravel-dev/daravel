@Tags(['security'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:daravel/daravel.dart';
import 'package:daravel/src/auth/bearer.dart';
import 'package:daravel/src/foundation/regexp_chars.dart';
import 'package:test/test.dart';

final class Member extends Model with AuthenticatableModel {
  static final ModelDefinition<Member> definition = ModelDefinition<Member>(
    table: 'members',
    factory: Member.new,
  );

  @override
  ModelDefinition<Member> get modelDefinition => Member.definition;
}

/// The bearer token is read in one pass. The regular expression it replaces,
/// `^\s*Bearer\s+(.+?)\s*$`, took time quadratic in a run of white space
/// inside the token, and the token and JWT guards ran it on every request
/// before looking anything up.
void main() {
  final old = RegExp(r'^\s*Bearer\s+(.+?)\s*$', caseSensitive: false);
  String? before(String header) => old.firstMatch(header)?.group(1);

  group('the same results as the regular expression', () {
    test('white space, line terminators and the letters of Bearer: every '
        'UTF-16 code unit', () {
      final space = RegExp(r'^\s$');
      final any = RegExp(r'^.$');
      final letters = {
        for (final letter in 'bear'.split(''))
          letter: RegExp('^$letter\$', caseSensitive: false),
      };
      for (var c = 0; c <= 0xFFFF; c++) {
        final char = String.fromCharCode(c);
        expect(isRegExpSpace(c), space.hasMatch(char), reason: '$c');
        expect(isLineTerminator(c), !any.hasMatch(char), reason: '$c');
        for (final MapEntry(key: letter, value: re) in letters.entries) {
          expect(
            (c | 0x20) == letter.codeUnitAt(0),
            re.hasMatch(char),
            reason: '$letter $c',
          );
        }
      }
    });

    test('values written out', () {
      String text(List<int> units) => String.fromCharCodes(units);
      final tab = text([9]);
      final lf = text([10]);
      final nbsp = text([0xA0]);
      final separator = text([0x2028]);
      for (final (header, token) in <(String, String?)>[
        ('Bearer abc', 'abc'),
        ('  bearer   abc  ', 'abc'),
        ('BEARER abc', 'abc'),
        ('${tab}Bearer${tab}a b$tab', 'a b'),
        ('Bearer${nbsp}abc$nbsp', 'abc'),
        ('Bearer', null),
        ('Bearer ', null),
        ('Bearer  ', ' '),
        ('Bearer $lf', null),
        ('Bearer  $lf', ' '),
        ('Bearer $separator ', ' '),
        ('Bearerabc', null),
        ('Basic abc', null),
        ('Bearer a${lf}b', null),
        ('Bearer ab$lf', 'ab'),
        ('Bearer 1|secret', '1|secret'),
        ('xBearer abc', null),
      ]) {
        expect(before(header), token, reason: jsonEncode(header));
        expect(
          bearerTokenFromHeader(header),
          token,
          reason: jsonEncode(header),
        );
      }
    });

    test('100 000 random values', () {
      final random = Random(20261113);
      final alphabet = <int>[
        0x20,
        0x09,
        0x0A,
        0x0B,
        0x0D,
        0xA0,
        0x2028,
        0x2029,
        0xFEFF,
        0x3000,
        0x62,
        0x42,
        0x65,
        0x61,
        0x72,
        0x52,
        0x78,
        0x7C,
        0x2E,
        0x17F,
        0x212A,
      ];
      const prefixes = [
        '',
        ' ',
        'Bearer',
        'bearer',
        'BEARER',
        'BeArEr',
        'Bearer ',
        'bearer  ',
        'Basic ',
        'Bear',
      ];
      for (var i = 0; i < 100000; i++) {
        final header =
            prefixes[random.nextInt(prefixes.length)] +
            String.fromCharCodes([
              for (var n = random.nextInt(9); n > 0; n--)
                alphabet[random.nextInt(alphabet.length)],
            ]);
        expect(
          bearerTokenFromHeader(header),
          before(header),
          reason: jsonEncode(header),
        );
      }
    });
  });

  // Three sizes, n, 8n and 64n: the step 8n to 64n is judged, about 8
  // linear and 64 quadratic; the limit of 32 sits between.
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

    for (final (label, header) in [
      ('white space inside the token', (int n) => 'Bearer a${' ' * n}b'),
      ('only white space after Bearer', (int n) => 'Bearer${' ' * n}'),
      ('white space before Bearer', (int n) => '${' ' * n}Bearer a'),
    ]) {
      test(label, () {
        final small = ms(() => bearerTokenFromHeader(header(50000)));
        final middle = ms(() => bearerTokenFromHeader(header(400000)));
        final large = ms(() => bearerTokenFromHeader(header(3200000)));
        final shown =
            '50 000: ${small.toStringAsFixed(2)} ms, 400 000: '
            '${middle.toStringAsFixed(2)} ms, 3 200 000: '
            '${large.toStringAsFixed(2)} ms';
        expect(large / middle, lessThan(32), reason: shown);
        expect(large, lessThan(5000), reason: shown);
      });
    }
  });

  group('through a socket, the guards', () {
    late ServerEngine engine;

    setUp(() async {
      final provider = ModelUserProvider<Member>(Member.definition);
      // `x|…` is refused by the token guard before the database is asked,
      // and the JWT guard refuses a token that is not three segments, so
      // what is timed is reading the header.
      final tokens = TokenGuard<Member>(name: 'api', provider: provider);
      final jwt = JwtGuard<Member>(
        name: 'jwt',
        provider: provider,
        codec: JwtCodec(
          keys: [
            HmacJwtKey.fromString('a-very-long-secret-of-at-least-32-bytes!'),
          ],
        ),
      );
      final app = Application.configure(basePath: Directory.systemTemp.path)
          .withEnv(const {'APP_ENV': 'testing', 'DB_DATABASE': ':memory:'})
          .withLogLevel(LogLevel.critical)
          .withRouting(
            web: (router) {
              router.get(
                '/token',
                (q) async => {'user': await tokens.resolveUser(q) != null},
              );
              router.get(
                '/jwt',
                (q) async => {'user': await jwt.resolveUser(q) != null},
              );
            },
          )
          .create();
      await app.boot();
      addTearDown(app.shutdown);
      engine = ServerEngine(
        app,
        // No header limits, as `HTTP_MAX_HEADER_BYTES=0` and
        // `HTTP_MAX_HEADER_LINE_BYTES=0` set them: the reading is timed, not
        // the 431 those limits answer (16 KiB per line by default, so the
        // regular expression cost at most about 2 s per request there).
        const ServeOptions(
          host: '127.0.0.1',
          port: 0,
          handleSignals: false,
          maxHeaderBytes: null,
          maxHeaderLineBytes: null,
        ),
        kernel: app.kernel,
        logger: Logger(handlers: [MemoryHandler()]),
      );
      await engine.start();
      addTearDown(engine.stop);
    });

    Future<(String, int)> get(String target, String authorization) async {
      final watch = Stopwatch()..start();
      final socket = await Socket.connect('127.0.0.1', engine.port!);
      socket.add(
        latin1.encode(
          'GET $target HTTP/1.1\r\nHost: h\r\nAccept: application/json\r\n'
          'Authorization: $authorization\r\nConnection: close\r\n\r\n',
        ),
      );
      await socket.flush();
      final reply = await utf8.decoder
          .bind(socket)
          .join()
          .timeout(const Duration(seconds: 60));
      socket.destroy();
      return (reply.split('\r\n').first, watch.elapsedMilliseconds);
    }

    // 32 768 spaces: about 7 s before (16 384: 1.9 s, 65 536: 31 s).
    for (final (target, token) in [('/token', 'x|a'), ('/jwt', 'a')]) {
      test(
        '$target: a long run of spaces inside the token answers at once',
        () async {
          final (status, ms) = await get(
            target,
            'Bearer $token${' ' * 32768}b',
          );
          expect(status, 'HTTP/1.1 200 OK');
          expect(ms, lessThan(2000), reason: '$ms ms');
        },
      );
    }
  });
}
