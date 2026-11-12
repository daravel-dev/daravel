import 'dart:math';

import 'package:daravel/daravel.dart';
import 'package:daravel/src/validation/dns.dart';
import 'package:daravel_test/daravel_test.dart';
import 'package:test/test.dart';

/// `toAsciiHost` refuses a name that cannot fit before [punycode] runs:
/// punycode takes time quadratic in the distinct code points of a label
/// (16 000 of them took 4 s), and `email:dns` hands it the domain of the
/// value as it is. The early refusals only skip work: the result is the
/// same as without them.
void main() {
  // The algorithm without the early refusals, for comparison.
  String? reference(String host) {
    var name = host.toLowerCase();
    if (name.endsWith('.')) {
      name = name.substring(0, name.length - 1);
    }
    if (name.isEmpty) {
      return null;
    }
    final labels = <String>[];
    for (final label in name.split('.')) {
      final ascii = label.codeUnits.every((c) => c < 0x80)
          ? label
          : 'xn--${punycode(label)}';
      if (ascii.isEmpty || ascii.length > 63) {
        return null;
      }
      labels.add(ascii);
    }
    final result = labels.join('.');
    return result.length > maxHostLength ? null : result;
  }

  String distinct(int n, [int from = 0x4E00]) =>
      String.fromCharCodes([for (var i = 0; i < n; i++) from + i]);

  test('the same result as without the early refusals', () {
    final random = Random(20261112);
    final hosts = <String>[
      // Labels around the 59 code point bound: all ASCII, one non-ASCII
      // code point, all non-ASCII.
      for (var n = 50; n <= 70; n++) ...[
        '${'a' * n}.com',
        '${'a' * (n - 1)}ü.com',
        'ü${'a' * (n - 1)}.com',
        '${distinct(n)}.com',
        '${'ü' * n}.com',
      ],
      // Names around 253 code points.
      for (var n = 240; n <= 260; n++) ...[
        [for (var i = 0; i < n ~/ 10; i++) 'abcdefghi'].join('.'),
        [for (var i = 0; i < n ~/ 10; i++) 'abcdefgh${'ü'}'].join('.'),
      ],
      'Bücher.DE.',
      '.',
      '',
    ];
    for (var i = 0; i < 2000; i++) {
      final labels = [
        for (var j = random.nextInt(4); j >= 0; j--)
          String.fromCharCodes([
            for (var k = random.nextInt(70); k >= 0; k--)
              random.nextBool()
                  ? 0x61 + random.nextInt(26)
                  : 0xE0 + random.nextInt(0x400),
          ]),
      ];
      hosts.add(labels.join('.'));
    }
    for (final host in hosts) {
      expect(toAsciiHost(host), reference(host), reason: host);
    }
  });

  // Growth, not a wall-clock bound: the time for 16 000 distinct code points
  // over the time for 4 000, each the fastest of three. Punycode before the
  // refusal grew about 16 times for 4 times the code points (267 ms and
  // 4 143 ms); when both are under a few milliseconds the ratio is noise.
  Future<int> fastest(Future<void> Function() run) async {
    var best = 1 << 62;
    for (var i = 0; i < 3; i++) {
      final watch = Stopwatch()..start();
      await run();
      best = min(best, watch.elapsedMicroseconds);
    }
    return best;
  }

  void linear(String name, Future<void> Function(String label) run) {
    test('$name: linear in the distinct code points of a label', () async {
      await run(distinct(100));
      final small = await fastest(() => run(distinct(4000)));
      final large = await fastest(() => run(distinct(16000)));
      expect(
        large < 5000 || large / max(small, 1) < 10,
        isTrue,
        reason: '4 000: $small µs, 16 000: $large µs',
      );
    });
  }

  final container = Container()..instance<DnsResolver>(FakeDnsResolver());
  Future<void> validate(String value, String rule) =>
      Validator({'v': value}, {'v': rule}, container: container).run();

  linear('toAsciiHost', (label) async => toAsciiHost('$label.com'));
  linear('email:dns', (label) => validate('a@$label.com', 'email:dns'));
  // active_url fails a non-ASCII host without a lookup (Laravel asks for
  // it as written), so it never reaches punycode; kept so it stays that way.
  linear('active_url', (label) => validate('http://$label.com', 'active_url'));

  // parse_url's host and the name pattern on long hosts: dots, '@', ':', a
  // long label, a bad character at the end.
  for (final (name, url) in [
    ('dotted labels', (int n) => 'http://${'a.' * (n ~/ 2)}com/'),
    ('one long label', (int n) => 'http://${'a' * n}.com/'),
    ('at signs', (int n) => 'http://${'@' * n}example.com/'),
    ('colons', (int n) => 'http://${'a:' * (n ~/ 2)}80/'),
    ('no scheme, a port', (int n) => '${'a' * n}:80'),
    ('labels then a bad character', (int n) => 'http://${'a.' * (n ~/ 2)}!/'),
  ]) {
    test('active_url: linear in the length of the host, $name', () async {
      await validate(url(1000), 'active_url');
      final small = await fastest(() => validate(url(25000), 'active_url'));
      final large = await fastest(() => validate(url(100000), 'active_url'));
      expect(
        large < 5000 || large / max(small, 1) < 10,
        isTrue,
        reason: '25 000: $small µs, 100 000: $large µs',
      );
    });
  }

  test('100 000 distinct code points end at once', () async {
    final label = distinct(100000, 0x20000);
    final watch = Stopwatch()..start();
    expect(toAsciiHost('$label.com'), isNull);
    await validate('a@$label.com', 'email:dns');
    // Far above what the refusal takes, far below the minutes punycode
    // would.
    expect(watch.elapsed, lessThan(const Duration(seconds: 5)));
  });
}
