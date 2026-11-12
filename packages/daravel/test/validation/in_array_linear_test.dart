import 'dart:math';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

/// `in_array` gathers the other values once per validation run (in
/// `ValidationContext.memo`) instead of walking the whole input for every
/// item, which took time quadratic in its size: 8 000 numbers against 8 000
/// took 52 s. The test is unchanged: `List.contains` of the value.
void main() {
  // A rule that is not implicit skips an absent value and a blank string.
  bool checked(Map<String, Object?> data, String attribute) {
    if (!ValidationContext.exists(data, attribute)) {
      return false;
    }
    final value = ValidationContext.dig(data, attribute);
    return !(value is String && value.trim().isEmpty);
  }

  // The rule as it decided before: one walk per item, without a memo.
  Set<String> before(Map<String, Object?> data, String pattern, String other) =>
      {
        for (final attribute in Validator.expandPattern(data, pattern))
          if (checked(data, attribute) &&
              InArrayRule(other).passes(
                    ValidationContext(
                      attribute: attribute,
                      pattern: pattern,
                      value: ValidationContext.dig(data, attribute),
                      present: true,
                      data: data,
                    ),
                  ) !=
                  null)
            attribute,
      };

  test('the same failures as one walk per item', () async {
    final random = Random(20261112);
    final values = <Object?>[
      1,
      2,
      1.0,
      '1',
      'a',
      'A',
      true,
      false,
      null,
      0,
      double.nan,
      [1],
      <String, Object?>{'k': 1},
    ];
    Object? value() => values[random.nextInt(values.length)];
    for (var i = 0; i < 1500; i++) {
      final nested = random.nextBool();
      final n = random.nextInt(6);
      final m = random.nextInt(6);
      final data = <String, Object?>{
        'items': [
          for (var j = 0; j < n; j++) nested ? {'id': value()} : value(),
        ],
        'others': [
          for (var j = 0; j < m; j++) nested ? {'id': value()} : value(),
        ],
      };
      final pattern = nested ? 'items.*.id' : 'items.*';
      final other = nested ? 'others.*.id' : 'others.*';
      final errors = await Validator(data, {pattern: 'in_array:$other'}).run();
      expect(
        errors.keys.toSet(),
        before(data, pattern, other),
        reason: '$data',
      );
    }
  });

  // Growth, not a wall-clock bound: 8 000 items against 8 000 over 500
  // against 500, each the fastest of three. Linear is about 16, the walk
  // per item about 256; the work allocates in proportion to the items, so
  // 16 times the size under 100 rather than 4 times under 10.
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

  for (final (name, data, rules) in [
    (
      'scalars',
      (int n) => <String, Object?>{
        'items': [for (var i = 0; i < n; i++) i],
        'others': [for (var i = 0; i < n; i++) i],
      },
      <String, Object>{'items.*': 'in_array:others.*'},
    ),
    (
      'items.*.id against others.*.id',
      (int n) => <String, Object?>{
        'items': [
          for (var i = 0; i < n; i++) {'id': i},
        ],
        'others': [
          for (var i = 0; i < n; i++) {'id': i},
        ],
      },
      <String, Object>{'items.*.id': 'in_array:others.*.id'},
    ),
  ]) {
    test('linear in the input size: $name', () async {
      await fastest(data(100), rules);
      final small = await fastest(data(500), rules);
      final large = await fastest(data(8000), rules);
      expect(
        large / max(small, 1),
        lessThan(100),
        reason: '500: $small µs, 8 000: $large µs',
      );
    });
  }
}
