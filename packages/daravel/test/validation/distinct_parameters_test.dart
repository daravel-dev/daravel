import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

/// `distinct:strict` and `distinct:ignore_case`, against Laravel 12.x
/// `ValidatesAttributes::validateDistinct`
/// (`src/Illuminate/Validation/Concerns/ValidatesAttributes.php` :881-890):
///
/// ```php
/// if (in_array('ignore_case', $parameters)) {
///     return empty(preg_grep('/^'.preg_quote($value, '/').'$/iu', $data));
/// }
/// return ! in_array($value, array_values($data), in_array('strict', $parameters));
/// ```
///
/// `ignore_case` is read first, so it wins over `strict`; any other
/// parameter is ignored, and `STRICT` is not `strict`. With
/// `ignore_case`, each value is compared as PHP writes it in a string
/// (`1.0` and `true` are `"1"`, `null` is `""`), whatever its case.
void main() {
  // The values of the table, and how PHP writes them in a string.
  const values = <(String, Object?, String)>[
    ('1', 1, '1'),
    ('"1"', '1', '1'),
    ('1.0', 1.0, '1'),
    ('true', true, '1'),
    ('null', null, ''),
    ('"a"', 'a', 'a'),
    ('"A"', 'A', 'A'),
  ];

  // PHP 8's `==` between two of them (`in_array` without `strict`): the
  // pairs of different values that are equal.
  const looseEqualPairs = {
    ('1', '"1"'),
    ('1', '1.0'),
    ('1', 'true'),
    ('"1"', '1.0'),
    ('"1"', 'true'),
    ('1.0', 'true'),
    ('true', '"a"'),
    ('true', '"A"'),
  };

  // Laravel's answer: whether item `x` fails beside item `y`.
  bool laravelFails(String mode, int x, int y) {
    final (a, va, sa) = values[x];
    final (b, vb, sb) = values[y];
    return switch (mode) {
      'ignore_case' => sa.toLowerCase() == sb.toLowerCase(),
      'strict' => x == y,
      _ =>
        x == y ||
            looseEqualPairs.contains((a, b)) ||
            looseEqualPairs.contains((b, a)),
    };
  }

  // Where this version answers otherwise, and why: without a parameter
  // the values are compared by their text, as in 1.27.7 (PHP's loose
  // comparison comes in 1.28.0). With a parameter, nowhere.
  String? knownDifference(String mode, int x, int y) {
    final (a, _, _) = values[x];
    final (b, _, _) = values[y];
    if (mode == '' && a != b && '${values[x].$2}' != '${values[y].$2}') {
      return 'without a parameter, values are compared by their text';
    }
    return null;
  }

  for (final mode in ['', 'strict', 'ignore_case']) {
    final rule = mode.isEmpty ? 'distinct' : 'distinct:$mode';
    test('$rule: every pair of 1, "1", 1.0, true, null, "a", "A"', () async {
      final differences = <String>[];
      for (var x = 0; x < values.length; x++) {
        for (var y = 0; y < values.length; y++) {
          final errors = await Validator(
            {
              'items': [values[x].$2, values[y].$2],
            },
            {'items.*': rule},
          ).run();
          final fails = errors.containsKey('items.0');
          final laravel = laravelFails(mode, x, y);
          final why = laravel != fails ? knownDifference(mode, x, y) : null;
          if (why != null) {
            differences.add('${values[x].$1} beside ${values[y].$1}: $why');
          } else {
            expect(
              fails,
              laravel,
              reason: '$rule: ${values[x].$1} beside ${values[y].$1}',
            );
          }
        }
      }
      // The differences, counted: only those listed above.
      // Both ways: 1 and "1" beside 1.0 and true, 1.0 beside true, true
      // beside "a" and "A" (equal loosely, not by their text).
      expect(
        differences.length,
        mode.isEmpty ? 14 : 0,
        reason: differences.join('\n'),
      );
    });
  }

  test('ignore_case wins over strict, as Laravel reads it first', () async {
    final errors = await Validator(
      {
        'items': ['a', 'A'],
      },
      {'items.*': 'distinct:strict,ignore_case'},
    ).run();
    expect(errors.keys.toSet(), {'items.0', 'items.1'});
  });

  test('an unknown parameter is ignored; STRICT is not strict', () async {
    for (final rule in ['distinct:foo', 'distinct:STRICT']) {
      final errors = await Validator(
        {
          'items': [1, '1'],
        },
        {'items.*': rule},
      ).run();
      expect(errors.keys.toSet(), {'items.0', 'items.1'}, reason: rule);
    }
  });

  test('strict: lists and maps equal only with the same keys, order and '
      'types', () async {
    Future<Set<String>> failing(List<Object?> items) async => (await Validator(
      {'items': items},
      {'items.*': 'distinct:strict'},
    ).run()).keys.toSet();
    expect(
      await failing([
        [1, 2],
        [1, 2],
      ]),
      {'items.0', 'items.1'},
    );
    expect(
      await failing([
        [1, 2],
        [1, '2'],
      ]),
      <String>{},
    );
    expect(
      await failing([
        {'a': 1, 'b': 2},
        {'b': 2, 'a': 1},
      ]),
      <String>{},
    );
  });

  test('ignore_case folds Unicode case as /iu does', () async {
    final errors = await Validator(
      {
        'items': ['Straße', 'STRAßE', 'é', 'É'],
      },
      {'items.*': 'distinct:ignore_case'},
    ).run();
    expect(errors.keys.toSet(), {'items.0', 'items.1', 'items.2', 'items.3'});
  });

  test('the parameters keep the groups of two wildcards and the shapes of '
      'this version', () async {
    final data = {
      'a': [
        {
          'items': {
            'x': {'id': 'A'},
            'y': {'id': 'a'},
          },
        },
        {
          'items': [
            {'id': 'a'},
          ],
        },
      ],
    };
    final errors = await Validator(data, {
      'a.*.items.*.id': 'distinct:ignore_case',
    }).run();
    expect(errors.keys.toSet(), {'a.0.items.x.id', 'a.0.items.y.id'});
    final strict = await Validator(data, {
      'a.*.items.*.id': 'distinct:strict',
    }).run();
    expect(strict.keys.toSet(), <String>{});
  });

  test('the typed rule takes the same parameters', () async {
    final errors = await Validator(
      {
        'items': [1, '1'],
      },
      {
        'items.*': [Rules.distinct(strict: true)],
      },
    ).run();
    expect(errors, isEmpty);
  });

  // Empty and dotted keys keep the answers of 1.27.7 under the
  // parameters: an empty key is compared with the others but not among
  // them; a key with a dot is neither (a known limit of this version).
  test('an empty key under a parameter: compared, not counted', () async {
    for (final rule in ['distinct:strict', 'distinct:ignore_case']) {
      final errors = await Validator(
        {
          'items': {'': 'a', 'x': 'a', 'y': 'b'},
        },
        {'items.*': rule},
      ).run();
      expect(errors.keys.toSet(), {'items.'}, reason: rule);
    }
  });

  test('a dotted key under a parameter: not compared (known limit)', () async {
    for (final rule in ['distinct:strict', 'distinct:ignore_case']) {
      final errors = await Validator(
        {
          'items': {
            'a.b': {'id': 'a'},
            'c': {'id': 'a'},
          },
        },
        {'items.*.id': rule},
      ).run();
      expect(errors, isEmpty, reason: rule);
    }
  });
}
