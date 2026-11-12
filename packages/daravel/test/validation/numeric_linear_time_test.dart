import 'dart:math';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

/// The exact-decimal reading of `decimal`, `multiple_of` and
/// `gt`/`gte`/`lt`/`lte` is linear in the length of the value (`size`,
/// `min`, `max` and `between` measure with `num.tryParse` and never used
/// it). Two regexes were quadratic: `^\s*…\s*$` retried
/// the trailing spaces for every leading one (100 000 spaces and a letter:
/// 53 s), and `decimal`'s `\d*\.?(\d*)` split a run of digits every way
/// (100 000 digits and a letter: 89 s). A JSON body may be 1 MiB.
void main() {
  /// The fastest of three runs, in microseconds: interference (GC, a busy
  /// runner) only ever slows a run down.
  Future<double> micros(Object? value, String rule) async {
    await Validator({'v': '1'}, {'v': rule}).run();
    var best = 1 << 62;
    for (var i = 0; i < 3; i++) {
      final watch = Stopwatch()..start();
      await Validator({'v': value}, {'v': rule}).run();
      if (watch.elapsedMicroseconds < best) {
        best = watch.elapsedMicroseconds;
      }
    }
    return best.toDouble();
  }

  // Growth, not a fixed time: from n to 16n characters a linear reading
  // takes about 16 times as long and the quadratic one took 256 times
  // (seconds); the limit of 100 sits far from both. A fixed 100 ms failed
  // on a slow CI runner at 104 ms, and n to 2n under 3 failed there at
  // 3.5; reading the text allocates in proportion to it, so one step of 4
  // is noisy, and 16 times the size evens that out.
  const n = 3125;
  for (final (rule, value) in [
    ('decimal:0,2', (int n) => '${'1' * n}x'),
    ('decimal:0,2', (int n) => '${'1' * (n ~/ 2)}.${'1' * (n ~/ 2)}x'),
    ('decimal:0,2', (int n) => '${' ' * n}x'),
    ('multiple_of:5', (int n) => '${' ' * n}x'),
    ('gt:5', (int n) => '${' ' * n}x'),
  ]) {
    test('$rule on ${value(n).length} and ${value(16 * n).length} '
        'characters: linear', () async {
      final small = await micros(value(n), rule);
      final large = await micros(value(16 * n), rule);
      final shown =
          '${(small / 1000).toStringAsFixed(1)} ms, then '
          '${(large / 1000).toStringAsFixed(1)} ms';
      // Below 1 ms, timer noise decides the ratio: linear either way.
      if (large > 1000) {
        expect(large / small, lessThan(100), reason: shown);
      }
      expect(large, lessThan(1000000), reason: '$shown (at most 1 s)');
    });
  }

  // The patterns before and after, on the same strings: both match or
  // neither, with the same captures.
  test('the new patterns read what the old ones read', () {
    final oldDecimal = RegExp(
      r'^\s*([+-]?)(\d*)(?:\.(\d*))?(?:[eE]([+-]?\d{1,4}))?\s*$',
    );
    final newDecimal = RegExp(
      r'^([+-]?)(\d*)(?:\.(\d*))?(?:[eE]([+-]?\d{1,4}))?$',
    );
    final space = RegExp(r'\s');
    String trim(String text) {
      var start = 0;
      var end = text.length;
      while (start < end && space.hasMatch(text[start])) {
        start++;
      }
      while (end > start && space.hasMatch(text[end - 1])) {
        end--;
      }
      return text.substring(start, end);
    }

    final oldPlaces = RegExp(r'^[+-]?\d*\.?(\d*)$');
    final newPlaces = RegExp(r'^[+-]?\d*(?:\.(\d*))?$');
    final random = Random(20261112);
    final pieces = [
      '1',
      '0',
      '9',
      '.',
      '+',
      '-',
      'e',
      'E',
      ' ',
      '\t',
      '\n',
      String.fromCharCode(0xA0),
      'x',
      '12',
      '..',
      '1e5',
      '-.',
      String.fromCharCode(0x2003),
    ];
    for (var i = 0; i < 20000; i++) {
      final text = [
        for (var j = random.nextInt(8); j >= 0; j--)
          pieces[random.nextInt(pieces.length)],
      ].join();
      final a = oldDecimal.firstMatch(text);
      final b = newDecimal.firstMatch(trim(text));
      expect(
        b == null,
        a == null,
        reason: 'decimal of ${Uri.encodeComponent(text)}',
      );
      if (a != null && b != null) {
        expect([b[1], b[2], b[3], b[4]], [a[1], a[2], a[3], a[4]]);
      }
      final c = oldPlaces.firstMatch(text);
      final d = newPlaces.firstMatch(text);
      expect(d == null, c == null, reason: 'places of $text');
      if (c != null && d != null) {
        expect((d[1] ?? '').length, c[1]!.length);
      }
    }
  });
}
