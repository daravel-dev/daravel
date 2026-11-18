import 'dart:math';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

/// Tokens built from a grammar of URLs (`redactUrlInText`, `redactUrl`):
/// credential forms whose secret is marked, benign URLs, separators and
/// benign tails, 1 to 4 URLs a token. Three properties:
///
/// - P1: no secret of a promised form is left in the output;
/// - P2: a token of benign URLs only comes out exactly as it went in;
/// - P3: every benign URL of a token comes out whole (masking stays inside
///   the URLs that carry credentials).
///
/// The forms the contract leaves out (a password holding `://`, one that
/// starts with digits and holds `?`, `#` or a second `/`) are not built:
/// see the known limits of `redactUrlPassword`.
void main() {
  // A secret marker: unique, and never a sensitive pair name.
  var secrets = 0;
  String secret() => 'Zq${secrets++}Xv';

  /// A URL carrying credentials, with the secret it hides.
  (String, String) credential(Random r) {
    final s = secret();
    final scheme = ['pgsql', 'redis', 'https', 'amqp'][r.nextInt(4)];
    final url = switch (r.nextInt(6)) {
      // A: user info in the authority.
      0 => '$scheme://app:$s@db.example.com/shop',
      // B: a password holding `/`, `?` or `#`, not starting with digits.
      1 => '$scheme://app:pa${['/', '?', '#'][r.nextInt(3)]}$s@db/shop',
      // C: a port-shaped password of digits, `/` and one segment.
      2 => '$scheme://my:1234/$s@cache/0',
      // C, with an `@` inside that segment.
      3 => '$scheme://my:1234/a@$s@cache/0',
      // D: a path segment `name:password@` after an authority without `:`.
      4 => '$scheme://gateway/app:$s@h1/p',
      // E: user info whose password holds an `@`.
      _ => '$scheme://app:p@$s@db.example.com/shop',
    };
    return (url, s);
  }

  /// A URL without credentials, promised to stay whole.
  String benign(Random r) => [
    'https://api.example.com/v1',
    'https://cdn.example.com:8443/assets',
    'https://h.example.com:8080',
    'pgsql://db.example.com/shop',
    'https://example.com/files/a@2x.png',
  ][r.nextInt(5)];

  /// A tail promised to stay whole.
  String tail(Random r) => [
    '',
    '?email=a@b.com',
    '/files/a@2x.png',
    ';contact=ops@example.com',
  ][r.nextInt(4)];

  /// The combinations left out, as the known limits of `redactUrlPassword`
  /// say: a host and port with no path, then `;name=value@…`. The authority
  /// runs to the first `/`, `?` or `#` (RFC 3986 §3.2), so
  /// `https://h:8080;contact=ops@example.com` holds user info `h` and
  /// password `8080;contact=ops`: it is masked, as such user info must be.
  bool excluded(String base, String tail) =>
      base == 'https://h.example.com:8080' && tail.startsWith(';');

  /// How the next URL follows: a separator, or nested in the path or the
  /// query of the one before.
  String join(Random r) =>
      [' ', ',', ';', '|', '&', '=', '/r/', '?next='][r.nextInt(8)];

  /// A token of [count] URLs: its text, its secrets, its benign URLs.
  (String, List<String>, List<String>) token(
    Random r,
    int count, {
    required bool benignOnly,
  }) {
    final text = StringBuffer();
    final hidden = <String>[];
    final kept = <String>[];
    for (var i = 0; i < count; i++) {
      if (i > 0) {
        text.write(join(r));
      }
      final t = tail(r);
      if (!benignOnly && r.nextBool()) {
        final (url, s) = credential(r);
        text.write('$url$t');
        hidden.add(s);
      } else {
        // A benign URL and its tail are kept whole together.
        final base = benign(r);
        final url = '$base${excluded(base, t) ? '' : t}';
        text.write(url);
        kept.add(url);
      }
    }
    return (text.toString(), hidden, kept);
  }

  test('P1 and P3: 6 000 tokens mixing credentials and benign URLs', () {
    final failures = <String>[];
    for (var seed = 0; seed < 6000; seed++) {
      final r = Random(seed);
      final (text, hidden, kept) = token(
        r,
        1 + r.nextInt(4),
        benignOnly: false,
      );
      for (final (name, out) in [
        ('redactUrlInText', redactUrlInText(text)),
        ('redactUrl', redactUrl(text)),
      ]) {
        for (final s in hidden) {
          if (out.contains(s)) {
            failures.add('P1 $name seed $seed: $text -> $out');
          }
        }
        for (final url in kept) {
          if (!out.contains(url)) {
            failures.add('P3 $name seed $seed: $url lost: $text -> $out');
          }
        }
      }
    }
    expect(failures.take(20), isEmpty, reason: '${failures.length} failures');
  });

  test('P2: 6 000 tokens of benign URLs and tails come out as they went '
      'in', () {
    final failures = <String>[];
    for (var seed = 0; seed < 6000; seed++) {
      final r = Random(seed);
      final (text, _, _) = token(r, 1 + r.nextInt(4), benignOnly: true);
      for (final (name, out) in [
        ('redactUrlInText', redactUrlInText(text)),
        ('redactUrl', redactUrl(text)),
      ]) {
        if (out != text) {
          failures.add('P2 $name seed $seed: $text -> $out');
        }
      }
    }
    expect(failures.take(20), isEmpty, reason: '${failures.length} failures');
  });

  test('linear: 256 KiB against 1 MiB of each hostile shape, best of 7 '
      'after a warm-up', () {
    const kib = 1024;
    final shapes = <String, String Function(int)>{
      'many @ in one path': (n) => 'x://h/${'a@' * (n ~/ 2)}',
      'many @ after a port': (n) => 'x://h:1/${'a@' * (n ~/ 2)}',
      'many @ after a non-port colon': (n) => 'x://u:p/${'a@' * (n ~/ 2)}',
      'many URLs side by side': (n) => 'x://u:p@h;' * (n ~/ 10),
      'many schemes at one authority': (n) => '${'a://' * (n ~/ 4)}u:p@h',
      'colons in a path': (n) => 'x://h/${':' * n}@',
    };
    for (final MapEntry(key: name, value: build) in shapes.entries) {
      final small = build(256 * kib);
      final large = build(1024 * kib);
      int time(String text) {
        final watch = Stopwatch()..start();
        redactUrlInText(text);
        redactUrl(text);
        return watch.elapsedMicroseconds;
      }

      time(small);
      time(large);
      var bestSmall = 1 << 62;
      var bestLarge = 1 << 62;
      for (var round = 0; round < 7; round++) {
        bestSmall = min(bestSmall, time(small));
        bestLarge = min(bestLarge, time(large));
      }
      final ratio = bestLarge / bestSmall;
      // Linear is 4; a scan per `@` or per URL is 16.
      expect(ratio, lessThan(8), reason: '$name: ${ratio.toStringAsFixed(2)}');
    }
  }, timeout: const Timeout(Duration(minutes: 2)));

  group('fixed seeds: the shapes found by review', () {
    for (final (input, expected) in [
      // One segment after a port, with an `@` inside it.
      ('redis://my:1234/a@S@h/0', 'redis://my:***@h/0'),
      // An `@` in the path and one in the query of the same URL.
      ('x://a/app:S@h1/p?email=a@b.com', 'x://a/app:***@h1/p?email=a@b.com'),
      ('x://a/app:S@h1/files/a@2x.png', 'x://a/app:***@h1/files/a@2x.png'),
      // Two URLs, no credentials: nothing changes.
      (
        'https://api.example.com:8443,https://cdn.example.com/files/a@2x.png',
        'https://api.example.com:8443,https://cdn.example.com/files/a@2x.png',
      ),
    ]) {
      test(input, () {
        expect(redactUrlInText(input), expected);
        expect(redactUrl(input), expected);
      });
    }
  });
}
