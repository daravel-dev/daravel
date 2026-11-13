import 'dart:math';

import 'package:daravel/daravel.dart';
// The function under test is not exported.
// ignore: implementation_imports
import 'package:daravel/src/validation/php_compare.dart';
import 'package:test/test.dart';

/// `phpNumeric` (behind `distinct` and `in_array`) and the digit rules
/// read their value one code unit at a time. The regular expressions they
/// used before kept a backtracking entry per repeat and threw a
/// `StackOverflowError` from about 4 200 000 characters; the results are
/// the same, checked against the expressions on random input.
void main() {
  // The code before, to compare against.
  final numeric = RegExp(
    r'^[ \t\n\r\v\f]*([+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?)'
    r'[ \t\n\r\v\f]*$',
  );
  num? before(String value) {
    final match = numeric.firstMatch(value);
    if (match == null) {
      return null;
    }
    final text = match[1]!;
    return text.contains(RegExp('[.eE]'))
        ? double.parse(text.endsWith('.') ? '${text}0' : text)
        : int.tryParse(text) ?? double.parse(text);
  }

  // What the input may hold: PHP's white space and its neighbours, signs,
  // digits, points, exponents, and letters a number is not made of.
  const alphabet = [
    ' ', '\t', '\n', '\r', '\v', '\f', ' ', //
    '+', '-', '.', 'e', 'E', 'x', 'X', 'o', 'b', 'a', '_', ',',
    '0', '1', '2', '5', '9',
  ];

  test('phpNumeric: the same number as the regular expression', () {
    final random = Random(330);
    var numbers = 0;
    var others = 0;
    final cases = <String>[
      '5',
      ' 1.5 ',
      '1e3',
      '.5',
      '5.',
      '5.e3',
      '-.5',
      '+5',
      '0x1A',
      '0o7',
      '0b1',
      '1_000',
      '1,5',
      '.',
      '',
      ' ',
      'e5',
      '1e',
      '1e+',
      '1e-5',
      'INF',
      'NAN',
      '-INF',
      '\v7\f',
      ' 7',
      '99999999999999999999',
      '1.5.2',
      '--1',
      '+-1',
      '1 2',
      for (var i = 0; i < 20000; i++)
        [
          for (var k = random.nextInt(12); k > 0; k--)
            alphabet[random.nextInt(alphabet.length)],
        ].join(),
      // Built in the shape of a number (white space, sign, digits, point,
      // exponent), one in four with one character changed.
      for (var i = 0; i < 5000; i++)
        () {
          String pick(List<String> from) => from[random.nextInt(from.length)];
          String digits() => [
            for (var k = random.nextInt(4); k > 0; k--) '${random.nextInt(10)}',
          ].join();
          final space = [' ', '\t', '\n', '\r', '\v', '\f', ''];
          var text =
              '${pick(space)}${pick(['', '+', '-'])}${digits()}'
              '${random.nextBool() ? '.${digits()}' : ''}'
              '${random.nextInt(3) == 0 ? '${pick(['e', 'E'])}${pick(['', '+', '-'])}${digits()}' : ''}'
              '${pick(space)}';
          if (text.isNotEmpty && random.nextInt(4) == 0) {
            final at = random.nextInt(text.length);
            text = text.replaceRange(at, at + 1, pick(alphabet));
          }
          return text;
        }(),
    ];
    for (final value in cases) {
      final expected = before(value);
      expected == null ? others++ : numbers++;
      final actual = phpNumeric(value);
      expect(
        actual is double && actual.isNaN ? 'NaN' : actual,
        expected is double && expected.isNaN ? 'NaN' : expected,
        reason: '"${value.replaceAll('\n', r'\n')}"',
      );
      expect(actual.runtimeType, expected.runtimeType, reason: '"$value"');
    }
    // Both kinds are well represented (printed for the record).
    expect(numbers, greaterThan(500));
    expect(others, greaterThan(500));
    printOnFailure('$numbers numeric, $others not');
  });

  test('digits, digits_between, min_digits, max_digits: as before', () async {
    final digitsOnly = RegExp(r'^\d+$');
    final random = Random(322);
    for (var i = 0; i < 3000; i++) {
      final value = [
        for (var k = random.nextInt(8); k > 0; k--)
          ['1', '2', '0', 'a', ' ', '.', '-', '٣'][random.nextInt(8)],
      ].join();
      if (value.trim().isEmpty) {
        continue; // the validator does not run these rules on a blank value
      }
      Future<bool> passes(String rule) async =>
          (await Validator({'f': value}, {'f': rule}).run()).isEmpty;
      final allDigits = digitsOnly.hasMatch(value);
      final noOther = !value.contains(RegExp('[^0-9]'));
      expect(
        await passes('digits:3'),
        allDigits && value.length == 3,
        reason: '"$value"',
      );
      expect(
        await passes('digits_between:2,4'),
        allDigits && value.length >= 2 && value.length <= 4,
      );
      expect(await passes('min_digits:3'), value.length >= 3 && noOther);
      expect(await passes('max_digits:3'), value.length <= 3 && noOther);
    }
  });

  test('8 000 000 characters: an answer, not a StackOverflowError', () async {
    final digits = '1' * 8000000;
    expect(phpNumeric(digits), double.infinity);
    expect(phpNumeric('$digits!'), isNull);
    for (final (data, rules) in [
      (
        {
          'f': [digits, '2'],
        },
        {'f.*': 'distinct'},
      ),
      (
        {
          'f': digits,
          'g': ['2'],
        },
        {'f': 'in_array:g.*'},
      ),
      ({'f': digits}, {'f': 'digits:5'}),
      ({'f': digits}, {'f': 'digits_between:1,5'}),
      ({'f': digits}, {'f': 'min_digits:5'}),
      ({'f': digits}, {'f': 'max_digits:5'}),
    ]) {
      await Validator(data, rules).run();
    }
  });

  // Growth: the fastest of three at n, 8n and 64n characters; linear is 8
  // per step.
  Future<int> fastest(
    Map<String, Object?> data,
    Map<String, Object> rules,
  ) async {
    var best = 1 << 62;
    for (var i = 0; i < 3; i++) {
      final watch = Stopwatch()..start();
      await Validator(data, rules).run();
      best = min(best, watch.elapsedMicroseconds);
    }
    return best;
  }

  for (final (name, make) in [
    (
      'distinct',
      (String v) => (
        <String, Object?>{
          'f': [v, '2'],
        },
        <String, Object>{'f.*': 'distinct'},
      ),
    ),
    (
      'digits_between',
      (String v) => (
        <String, Object?>{'f': v},
        <String, Object>{'f': 'digits_between:1,5'},
      ),
    ),
    (
      'min_digits',
      (String v) =>
          (<String, Object?>{'f': v}, <String, Object>{'f': 'min_digits:5'}),
    ),
  ]) {
    test('$name grows linearly', () async {
      const n = 8000;
      final times = <int>[];
      for (final size in [n, 8 * n, 64 * n]) {
        final (data, rules) = make('1' * size);
        times.add(await fastest(data, rules));
      }
      expect(times[2] / max(times[1], 2000), lessThan(32), reason: '$times');
    });
  }
}
