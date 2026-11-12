import 'dart:math';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

/// `distinct` counts the list once per validation run (in
/// `ValidationContext.memo`) instead of scanning it for every item, which
/// took time quadratic in its length: 16 000 numbers took 15 s, 16 000
/// `items.*.id` 55 s. What it compares is unchanged: the items' text, among
/// the siblings of the enclosing list.
void main() {
  // The rule as it decided before: one scan of the list per item, through
  // a context without a memo, for the attributes the validator checks (a
  // rule that is not implicit skips an absent value and a blank string).
  bool checked(Map<String, Object?> data, String attribute) {
    if (!ValidationContext.exists(data, attribute)) {
      return false;
    }
    final value = ValidationContext.dig(data, attribute);
    return !(value is String && value.trim().isEmpty);
  }

  Set<String> before(Map<String, Object?> data, String pattern) => {
    for (final attribute in Validator.expandPattern(data, pattern))
      if (checked(data, attribute) &&
          const DistinctRule().passes(
                ValidationContext(
                  attribute: attribute,
                  pattern: pattern,
                  value: ValidationContext.dig(data, attribute),
                  present: ValidationContext.exists(data, attribute),
                  data: data,
                ),
              ) !=
              null)
        attribute,
  };

  test('the same failures as one scan per item', () async {
    final random = Random(20261112);
    final values = <Object?>[
      1,
      2,
      1.0,
      '1',
      '1.0',
      'a',
      'A',
      '',
      ' a',
      true,
      false,
      null,
      0,
      '0',
    ];
    Object? value() => values[random.nextInt(values.length)];
    for (var i = 0; i < 1500; i++) {
      final n = random.nextInt(8);
      final Map<String, Object?> data;
      final String pattern;
      switch (random.nextInt(3)) {
        case 0:
          data = {
            'items': [for (var j = 0; j < n; j++) value()],
          };
          pattern = 'items.*';
        case 1:
          data = {
            'items': [
              for (var j = 0; j < n; j++)
                random.nextInt(5) == 0 ? <String, Object?>{} : {'id': value()},
            ],
          };
          pattern = 'items.*.id';
        default:
          data = {
            'items': [
              for (var j = 0; j < n; j++)
                {
                  'tags': [for (var k = random.nextInt(4); k > 0; k--) value()],
                },
            ],
          };
          pattern = 'items.*.tags.*';
      }
      final errors = await Validator(data, {pattern: 'distinct'}).run();
      expect(errors.keys.toSet(), before(data, pattern), reason: '$data');
    }
  });

  // Growth, not a wall-clock bound: 16 000 items over 4 000, each the
  // fastest of three. Linear is about 4, the scan per item about 16.
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
      },
      <String, Object>{'items.*': 'distinct'},
    ),
    (
      'items.*.id',
      (int n) => <String, Object?>{
        'items': [
          for (var i = 0; i < n; i++) {'id': i},
        ],
      },
      <String, Object>{'items.*.id': 'distinct'},
    ),
  ]) {
    test('linear in the list length: $name', () async {
      await fastest(data(100), rules);
      final small = await fastest(data(4000), rules);
      final large = await fastest(data(16000), rules);
      expect(
        large / max(small, 1),
        lessThan(10),
        reason: '4 000: $small µs, 16 000: $large µs',
      );
    });
  }
}
