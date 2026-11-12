import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:daravel/daravel.dart';
import 'package:daravel/src/http/multipart.dart';
import 'package:mime/mime.dart';
import 'package:test/test.dart';

/// A multipart part's header block is bounded before `package:mime`
/// buffers it ([MultipartLimits.maxPartHeaderBytes], `maxPartHeaders`),
/// and the scanner doing it passes every body through unchanged.
void main() {
  const boundary = 'XyZ-boundary';
  const disposition = 'content-disposition: form-data; name="a"';

  /// One field `a` whose header block holds [padding] more bytes in an
  /// `x-pad` header, and [extra] more header lines.
  String body({int padding = 0, int extra = 0}) =>
      '--$boundary\r\n'
      '$disposition\r\n'
      '${padding > 0 ? 'x-pad: ${'p' * padding}\r\n' : ''}'
      '${'x-h: 1\r\n' * extra}'
      '\r\n'
      'value\r\n'
      '--$boundary--\r\n';

  // The block: CRLF ending the delimiter line, the lines with their CRLF,
  // and the blank line's CRLF.
  final blockOf = 2 + disposition.length + 2 + 2;

  List<List<int>> split(String text, List<int> at) {
    final bytes = latin1.encode(text);
    final cuts = [0, ...at, bytes.length];
    return [
      for (var i = 0; i + 1 < cuts.length; i++)
        bytes.sublist(cuts[i], cuts[i + 1]),
    ];
  }

  void scan(List<List<int>> chunks, {int maxBytes = 1 << 20, int max = 100}) {
    final scanner = PartHeaderScanner(
      boundary,
      maxBytes: maxBytes,
      maxHeaders: max,
    );
    chunks.forEach(scanner.add);
  }

  group('PartHeaderScanner', () {
    test('a block at the byte limit passes, one byte more fails', () {
      expect(
        () => scan([latin1.encode(body())], maxBytes: blockOf),
        returnsNormally,
      );
      // x-pad: <n>\r\n adds 7 + n + 2 bytes.
      final padded = blockOf + 7 + 10 + 2;
      expect(
        () => scan([latin1.encode(body(padding: 10))], maxBytes: padded),
        returnsNormally,
      );
      expect(
        () => scan([latin1.encode(body(padding: 11))], maxBytes: padded),
        throwsA(isA<BadRequestHttpException>()),
      );
    });

    test('the header line limit: the disposition and 99 more pass, 100 '
        'more fail', () {
      expect(() => scan([latin1.encode(body(extra: 99))]), returnsNormally);
      expect(
        () => scan([latin1.encode(body(extra: 100))]),
        throwsA(isA<BadRequestHttpException>()),
      );
    });

    test('the same verdict wherever the body is cut', () {
      final fits = body(padding: 10);
      final over = body(padding: 11);
      final limit = blockOf + 7 + 10 + 2;
      for (var at = 1; at < fits.length; at++) {
        expect(
          () => scan(split(fits, [at]), maxBytes: limit),
          returnsNormally,
          reason: 'cut at $at',
        );
      }
      for (var at = 1; at < over.length; at++) {
        expect(
          () => scan(split(over, [at]), maxBytes: limit),
          throwsA(isA<BadRequestHttpException>()),
          reason: 'cut at $at',
        );
      }
      // One byte per chunk.
      expect(
        () => scan(
          split(over, [for (var i = 1; i < over.length; i++) i]),
          maxBytes: limit,
        ),
        throwsA(isA<BadRequestHttpException>()),
      );
    });

    test('content that looks like a delimiter without the CRLF is content', () {
      // `--XyZ-boundary` inside the value, not after CRLF, and a CR LF
      // followed by a near miss.
      final text =
          '--$boundary\r\n$disposition\r\n\r\n'
          'a--$boundary${'h' * 100}\r\n--XyZ-boundar\r\n'
          '${'y' * 5000}\r\n--$boundary--\r\n';
      expect(
        () => scan([latin1.encode(text)], maxBytes: blockOf),
        returnsNormally,
      );
    });

    test('a preamble before the first delimiter is skipped', () {
      final text = 'preamble ${'z' * 50}\r\n${body()}';
      expect(
        () => scan([latin1.encode(text)], maxBytes: blockOf),
        returnsNormally,
      );
    });
  });

  test('parseMultipart refuses a part header above 16 KiB with 400', () async {
    Future<Object?> parse(String text) => parseMultipart(
      Stream.value(latin1.encode(text)),
      boundary,
    ).then((b) => b.fields['a'], onError: (Object e) => e);
    final room = 16 * 1024 - blockOf - 9;
    expect(await parse(body(padding: room)), 'value');
    final refused = await parse(body(padding: room + 1));
    expect(refused, isA<BadRequestHttpException>());
    expect((refused! as HttpException).status, 400);
  });

  test('the same parts as package:mime alone, on 2 000 random bodies cut '
      'at random', () async {
    final random = Random(20261112);
    const alphabet = 'ab-\r\n"; =X';
    String noise(int max, [String from = alphabet]) => String.fromCharCodes([
      for (var i = random.nextInt(max); i > 0; i--)
        from.codeUnitAt(random.nextInt(from.length)),
    ]);
    String randomBody() {
      final b = StringBuffer();
      if (random.nextInt(4) == 0) b.write('${noise(20)}\r\n');
      for (var p = random.nextInt(4); p >= 0; p--) {
        b.write('--$boundary${random.nextInt(5) == 0 ? '  ' : ''}\r\n');
        for (var h = random.nextInt(4); h > 0; h--) {
          b.write(
            // A valid header value, mostly; one in 20 gets a stray CR or LF.
            'x-${random.nextInt(9)}: '
            '${noise(30, random.nextInt(20) == 0 ? alphabet : 'ab-"; =X')}\r\n',
          );
        }
        b.write('\r\n${noise(60)}');
        if (random.nextBool()) {
          b.write('\r\n--$boundary'.substring(0, 1 + random.nextInt(14)));
        }
        b.write('\r\n');
      }
      b.write('--$boundary--${random.nextBool() ? '\r\n' : ''}');
      if (random.nextInt(5) == 0) b.write(noise(10));
      return b.toString();
    }

    // package:mime throws some parse errors synchronously in its listener,
    // where they escape as zone errors (as in parseMultipart): each run
    // gets a guarded zone, and the first error ends it.
    Future<String> parts(Stream<List<int>> stream) {
      final done = Completer<String>();
      final out = StringBuffer();
      void fail(Object error) {
        if (!done.isCompleted) {
          done.complete('$out error ${error.runtimeType}');
        }
      }

      runZonedGuarded(() async {
        try {
          await for (final part in MimeMultipartTransformer(
            boundary,
          ).bind(stream)) {
            out.write('${part.headers}|');
            out.write(
              latin1.decode([for (final c in await part.toList()) ...c]),
            );
            out.write('#');
          }
          if (!done.isCompleted) {
            done.complete(out.toString());
          }
        } on Object catch (error) {
          fail(error);
        }
      }, (error, _) => fail(error));
      // A part left pending by an error on the parts stream (#145) never
      // ends: that is a result too, and must be the same on both paths.
      return done.future.timeout(
        const Duration(milliseconds: 200),
        onTimeout: () => '$out hang',
      );
    }

    const generous = MultipartLimits(
      maxPartHeaderBytes: 1 << 20,
      maxPartHeaders: 1 << 20,
    );
    var errors = 0;
    var hangs = 0;
    for (var i = 0; i < 2000; i++) {
      final text = randomBody();
      final cuts = [
        for (var c = random.nextInt(4); c > 0; c--)
          1 + random.nextInt(text.length - 1),
      ]..sort();
      final chunks = split(text, cuts.toSet().toList()..sort());
      final alone = await parts(Stream.fromIterable(chunks));
      if (alone.contains(' error ')) errors++;
      if (alone.endsWith(' hang')) hangs++;
      expect(
        await parts(
          limitPartHeaders(Stream.fromIterable(chunks), boundary, generous),
        ),
        alone,
        reason: 'body $i: ${jsonEncode(text)}',
      );
    }
    // ignore: avoid_print
    print('equivalence: 2000 bodies, $errors errors, $hangs hangs');
  }, timeout: const Timeout(Duration(minutes: 5)));
}
