import 'dart:math';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

/// `gt`, `gte`, `lt`, `lte`, `decimal` and `multiple_of` read a numeric
/// value without `BigInt.parse` of its digits, which was quadratic in their
/// length (1 000 000 digits held a request for 35 to 46 s). The results are
/// those of the code before, checked against a copy of it on random input,
/// and the time grows linearly.
void main() {
  // The code before, as it was, to compare against.
  final pattern = RegExp(r'^([+-]?)(\d*)(?:\.(\d*))?(?:[eE]([+-]?\d{1,4}))?$');
  (BigInt, int)? before(Object? value) {
    if (value is! String && value is! num) {
      return null;
    }
    final match = pattern.firstMatch('$value'.trim());
    if (match == null) {
      return null;
    }
    final whole = match[2]!;
    final fraction = match[3] ?? '';
    if (whole.isEmpty && fraction.isEmpty) {
      return null;
    }
    final digits = BigInt.parse('$whole$fraction');
    final exponent = int.parse(match[4] ?? '0');
    var scale = fraction.length - exponent;
    var unscaled = match[1] == '-' ? -digits : digits;
    if (scale < 0) {
      unscaled *= BigInt.from(10).pow(-scale);
      scale = 0;
    }
    return (unscaled, scale);
  }

  (BigInt, BigInt) aligned((BigInt, int) a, (BigInt, int) b) {
    final scale = max(a.$2, b.$2);
    BigInt at((BigInt, int) n) => n.$1 * BigInt.from(10).pow(scale - n.$2);
    return (at(a), at(b));
  }

  final random = Random(330);
  String digits(int most) =>
      [for (var i = random.nextInt(most + 1); i > 0; i--) random.nextInt(10)]
          .join();

  /// A value as a client may send it: signs, zeros in front and behind,
  /// a point without digits, exponents, spaces around, or not a number.
  String value({bool numeric = false}) {
    // Not '': the validator does not run these rules on an empty value.
    if (!numeric && random.nextInt(10) == 0) {
      return ['.', '-', 'e5', '1e', '1..2', ' x', '1 2', '+-1'][random.nextInt(
        8,
      )];
    }
    final sign = ['', '', '-', '+'][random.nextInt(4)];
    final zeros = '0' * random.nextInt(3);
    var whole = '$zeros${digits(random.nextInt(6) == 0 ? 60 : 5)}';
    var fraction = random.nextBool()
        ? '.${digits(random.nextInt(6) == 0 ? 60 : 4)}${'0' * random.nextInt(3)}'
        : '';
    if (whole.isEmpty && fraction.length < 2) {
      whole = '${random.nextInt(10)}';
      fraction = '';
    }
    final exponent = random.nextInt(5) == 0
        ? '${random.nextBool() ? 'e' : 'E'}${['', '+', '-'][random.nextInt(3)]}'
              '${random.nextInt(40)}'
        : '';
    final space = random.nextInt(8) == 0 ? ' ' : '';
    return '$space$sign$whole$fraction$exponent$space';
  }

  Future<bool> passes(Map<String, Object?> data, String rule) async =>
      (await Validator(data, {'f': rule}).run()).isEmpty;

  test(
    'gt, gte, lt, lte against a number: as before, on 3 000 values',
    () async {
      for (var i = 0; i < 3000; i++) {
        final v = value();
        final target = before(value(numeric: true));
        if (target == null) {
          continue;
        }
        // The literal the rule reads, written plainly.
        final literal = '${target.$1}e-${target.$2}';
        final mine = before(v);
        for (final (name, holds) in [
          ('gt', (int o) => o > 0),
          ('gte', (int o) => o >= 0),
          ('lt', (int o) => o < 0),
          ('lte', (int o) => o <= 0),
        ]) {
          final expected =
              mine != null &&
              (() {
                final (a, b) = aligned(mine, before(literal)!);
                return holds(a.compareTo(b));
              })();
          expect(
            await passes({'f': v}, '$name:$literal'),
            expected,
            reason: '"$v" $name:$literal',
          );
        }
      }
    },
  );

  test('gt against another numeric field: as before', () async {
    for (var i = 0; i < 2000; i++) {
      final v = value(numeric: true);
      final other = value(numeric: true);
      final (a, b) = aligned(before(v)!, before(other)!);
      expect(
        await passes({'f': v, 'b': other}, 'gt:b'),
        a.compareTo(b) > 0,
        reason: '"$v" gt "$other"',
      );
    }
  });

  test('multiple_of: as before, on 3 000 values', () async {
    for (var i = 0; i < 3000; i++) {
      final v = value();
      final factor = before(
        [
          '3',
          '0.5',
          '0.1',
          '7',
          '12.5',
          '0.003',
          '1e2',
          '2.5e-3',
          '-4',
          '1000',
        ][random.nextInt(10)],
      )!;
      final written = '${factor.$1}e-${factor.$2}';
      final mine = before(v);
      final expected =
          mine != null &&
          (() {
            final (a, b) = aligned(mine, factor);
            return a.remainder(b) == BigInt.zero;
          })();
      expect(
        await passes({'f': v}, 'multiple_of:$written'),
        expected,
        reason: '"$v" multiple_of:$written',
      );
    }
  });

  test('decimal: the shape, as before', () async {
    for (var i = 0; i < 2000; i++) {
      final v = value();
      final places = RegExp(r'^[+-]?\d*(?:\.(\d*))?$').firstMatch(v);
      final count = (places?[1] ?? '').length;
      expect(
        await passes({'f': v}, 'decimal:0,3'),
        before(v) != null && places != null && count <= 3,
        reason: '"$v"',
      );
    }
  });

  test('zero, signs and exponents at the edges', () async {
    expect(await passes({'f': '-0'}, 'gte:0'), isTrue);
    expect(await passes({'f': '0.000'}, 'lte:-0'), isTrue);
    expect(await passes({'f': '1e9999'}, 'gt:9e9998'), isTrue);
    expect(await passes({'f': '1e-9999'}, 'gt:0'), isTrue);
    expect(await passes({'f': '1e-9999'}, 'lt:1e-9998'), isTrue);
    expect(await passes({'f': '0'}, 'multiple_of:0.5'), isTrue);
    expect(await passes({'f': '1e4'}, 'multiple_of:2.5e-3'), isTrue);
    expect(await passes({'f': '0.0025'}, 'multiple_of:2.5e-3'), isTrue);
    expect(await passes({'f': '0.0026'}, 'multiple_of:2.5e-3'), isFalse);
    expect(await passes({'f': '5'}, 'multiple_of:0'), isFalse);
  });

  // What Laravel 13.40 answers for the same long values (Brick's
  // BigDecimal, exact: no rounding past float precision), from the
  // interop image: `Validator::make(['f' => $value], ['f' => $rule])`.
  test('long values: what Laravel 13.40 answers', () async {
    final million = '1' * 1000000;
    for (final (rule, value, passesInLaravel) in [
      ('gt:5', million, true),
      ('lt:5', million, false),
      ('gte:5', million, true),
      ('decimal:2', '$million.00', true),
      ('multiple_of:3', million, false),
      ('multiple_of:0.5', '0.${'0' * 1000000}1', false),
      ('gt:${'1' * 400}', '${'1' * 399}2', true),
      ('gt:${'1' * 401}', '${'1' * 400}2', true),
      ('gt:100000000000000000001', '100000000000000000002', true),
      ('lt:1e400', '1e399', true),
    ]) {
      expect(
        await passes({'f': value}, rule),
        passesInLaravel,
        reason:
            '${rule.length > 30 ? rule.substring(0, 30) : rule} on '
            '${value.length} characters',
      );
    }
  });

  // Growth, not a wall-clock bound: the fastest of three at n, 8n and 64n
  // digits. Linear is 8 per step; the code before took about 50.
  Future<int> fastest(Map<String, Object?> data, String rule) async {
    var best = 1 << 62;
    for (var i = 0; i < 3; i++) {
      final watch = Stopwatch()..start();
      await Validator(data, {'f': rule}).run();
      best = min(best, watch.elapsedMicroseconds);
    }
    return best;
  }

  String ones(int n) => '1' * n;
  for (final (rule, make) in [
    ('gt:5', ones),
    ('gte:5', ones),
    ('lt:5', ones),
    ('lte:5', ones),
    ('gt:b', ones),
    ('decimal:2', (int n) => '${ones(n)}.00'),
    ('multiple_of:3', ones),
    ('multiple_of:0.5', (int n) => '0.${'0' * n}1'),
    ('numeric|between:1,5', ones),
    ('numeric|size:5', ones),
    ('same:b', ones),
    ('different:b', ones),
    ('digits_between:1,5', ones),
    ('min_digits:5', ones),
    ('in:1,2,3', ones),
  ]) {
    test('$rule grows linearly with the digits', () async {
      const n = 8000;
      final times = [
        for (final size in [n, 8 * n, 64 * n])
          await fastest({'f': make(size), 'b': ones(size ~/ 2 + 1)}, rule),
      ];
      expect(
        times[2] / max(times[1], 2000),
        lessThan(32),
        reason: '$rule: $times µs',
      );
    });
  }
}
