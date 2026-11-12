import 'dart:math';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

/// `distinct` counts the values once per validation run (in
/// `ValidationContext.memo`) instead of scanning them for every item, which
/// took time quadratic in their number: 16 000 numbers took 15 s, 16 000
/// `items.*.id` 55 s. What it decides is checked against Laravel in
/// `distinct_in_array_golden_test.dart` and `_reference_test.dart`.
void main() {
  // The rule through a context without a memo, so it counts the values for
  // every item, for the attributes the validator checks (a rule that is
  // not implicit skips an absent value and a blank string).
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

  test('the same failures with and without the memo', () async {
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

  // Growth, not a wall-clock bound: 16 000 items over 1 000, each the
  // fastest of three. Linear is about 16, the scan per item about 256. The
  // work allocates in proportion to the items, so one step of 4 can read 6
  // or 7 when a collection lands in it; 16 times the size under 100 holds
  // through that and still fails a quadratic.
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
    (
      'strict',
      (int n) => <String, Object?>{
        'items': [for (var i = 0; i < n; i++) i.isEven ? i : '$i'],
      },
      <String, Object>{'items.*': 'distinct:strict'},
    ),
    (
      'ignore_case, distinct strings',
      (int n) => <String, Object?>{
        'items': [for (var i = 0; i < n; i++) 'Name$i'],
      },
      <String, Object>{'items.*': 'distinct:ignore_case'},
    ),
    (
      'items.*.tags.* across items',
      (int n) => <String, Object?>{
        'items': [
          for (var i = 0; i < n ~/ 4; i++)
            {
              'tags': [for (var j = 0; j < 4; j++) i * 4 + j],
            },
        ],
      },
      <String, Object>{'items.*.tags.*': 'distinct'},
    ),
  ]) {
    test('linear in the list length: $name', () async {
      await fastest(data(100), rules);
      final small = await fastest(data(1000), rules);
      final large = await fastest(data(16000), rules);
      expect(
        // Under 5 ms the ratio is timer noise: linear either way.
        large < 5000 || large / max(small, 1) < 100,
        isTrue,
        reason: '1 000: $small µs, 16 000: $large µs',
      );
    });
  }
}
