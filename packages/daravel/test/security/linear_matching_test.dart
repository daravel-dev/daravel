@Tags(['security'])
library;

import 'dart:math';

import 'package:daravel/src/foundation/glob.dart';
import 'package:daravel/src/http/multipart.dart';
import 'package:test/test.dart';

/// A backslash, built in code (escapes in a test's source are easy to get
/// wrong, and these patterns are made of them).
final String b = String.fromCharCode(92);

/// What the origin check and the HTTP fake did before: `*` as `.*`.
bool oldGlob(String pattern, String text) =>
    RegExp('^${pattern.split('*').map(RegExp.escape).join('.*')}\$')
        .hasMatch(text);

/// What `_parseDisposition` did before.
List<(String, String)> oldDisposition(String header) => [
  for (final match in RegExp(
    '([A-Za-z*]+)${b}s*=${b}s*(?:"((?:$b$b.|[^"$b$b])*)"|([^;]*))',
  ).allMatches(header))
    (
      match.group(1)!,
      match.group(2)?.replaceAllMapped(RegExp('$b$b(.)'), (m) => m[1]!) ??
          match.group(3)!.trim(),
    ),
];

String randomText(Random r, String alphabet, int max) => String.fromCharCodes([
  for (var i = r.nextInt(max + 1); i > 0; i--)
    alphabet.codeUnitAt(r.nextInt(alphabet.length)),
]);

/// Matching that a client's input reaches must take time linear in it:
/// the regular expressions these replace backtracked for minutes on a few
/// kilobytes (an `Origin` header, a multipart part's header).
void main() {
  group('globMatches (Str::is)', () {
    test('agrees with the regular expression it replaces, on 20 000 random '
        'patterns and texts', () {
      final r = Random(7);
      for (var i = 0; i < 20000; i++) {
        final pattern = randomText(r, 'ab*.', 6);
        final text = randomText(r, 'ab.', 10);
        expect(
          globMatches(pattern, text),
          oldGlob(pattern, text),
          reason: '"$pattern" on "$text"',
        );
      }
    });

    test('origin patterns as configured', () {
      expect(globMatches('*.example.com', 'app.example.com'), isTrue);
      expect(globMatches('*.example.com', 'example.com'), isFalse);
      expect(globMatches('example.com', 'example.com'), isTrue);
      expect(globMatches('*', ''), isTrue);
      expect(globMatches('a*b*c', 'abc'), isTrue);
      expect(globMatches('a*b*c', 'acb'), isFalse);
      expect(globMatches('ab*ba', 'aba'), isFalse);
    });

    test('a host of 64 000 characters against *.*.*.example.com: linear '
        '(the regular expression took over 100 s at 8 000)', () {
      final host = '${'a.' * 32000}x';
      final watch = Stopwatch()..start();
      expect(globMatches('*.*.*.example.com', host), isFalse);
      // Linear: a few ms (cold); the regular expression took 79 to over
      // 100 s. 1 s leaves room for a slow CI runner.
      expect(watch.elapsed, lessThan(const Duration(seconds: 1)));
    });
  });

  group('Content-Disposition parameters', () {
    test('agree with the regular expression they replace, on 20 000 random '
        'headers', () {
      final r = Random(11);
      final alphabet = 'aB*=";  ;x$b';
      for (var i = 0; i < 20000; i++) {
        final header = randomText(r, alphabet, 24);
        expect(
          dispositionParameters(header).toList(),
          oldDisposition(header),
          reason: header,
        );
      }
    });

    test('the headers browsers send', () {
      expect(dispositionParameters('form-data; name="a"; filename="b.png"'), [
        ('name', 'a'),
        ('filename', 'b.png'),
      ]);
      expect(
        dispositionParameters(
          'form-data; name="f"; filename*=UTF-8'
          "''na%C3%AFve.txt",
        ).last.$1,
        'filename*',
      );
      expect(dispositionParameters('form-data; name="say $b"hi$b""').single, (
        'name',
        'say "hi"',
      ));
    });

    test('64 000 letters without "=": linear (the regular expression took '
        '79 s)', () {
      final header = 'a' * 64000;
      final watch = Stopwatch()..start();
      expect(dispositionParameters(header), isEmpty);
      // Linear: a few ms (cold); the regular expression took 79 to over
      // 100 s. 1 s leaves room for a slow CI runner.
      expect(watch.elapsed, lessThan(const Duration(seconds: 1)));
    });
  });
}
