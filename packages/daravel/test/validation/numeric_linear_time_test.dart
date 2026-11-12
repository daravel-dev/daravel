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
  Future<int> millis(Object? value, String rule) async {
    await Validator({'v': '1'}, {'v': rule}).run();
    final watch = Stopwatch()..start();
    await Validator({'v': value}, {'v': rule}).run();
    return watch.elapsedMilliseconds;
  }

  const n = 50000;
  for (final (rule, value) in [
    ('decimal:0,2', '${'1' * n}x'),
    ('decimal:0,2', '${'1' * (n ~/ 2)}.${'1' * (n ~/ 2)}x'),
    ('decimal:0,2', '${' ' * n}x'),
    ('multiple_of:5', '${' ' * n}x'),
    ('gt:5', '${' ' * n}x'),
  ]) {
    test('$rule on ${value.length} characters', () async {
      expect(await millis(value, rule), lessThan(100));
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
