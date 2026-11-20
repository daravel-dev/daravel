import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:daravel/src/validation/case_folding.g.dart';
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

  test('strict treats -0.0 and 0.0 as equal (PHP -0.0 === 0.0)', () async {
    final errors = await Validator(
      {
        'items': [-0.0, 0.0],
      },
      {'items.*': 'distinct:strict'},
    ).run();
    expect(errors.keys.toSet(), {'items.0', 'items.1'});
  });

  test('ignore_case follows PCRE2 Unicode 14-15 (C+S) case folding', () async {
    // U+0130 (İ) and U+0131 (ı) do not fold to i in Unicode C+S or PCRE2.
    expect(
      await Validator(
        {
          'items': ['\u0130', '\u0131', 'i'],
        },
        {'items.*': 'distinct:ignore_case'},
      ).run(),
      isEmpty,
    );
    // U+1E9E (ẞ) folds to U+00DF (ß).
    expect(
      (await Validator(
        {
          'items': ['\u1E9E', '\u00DF'],
        },
        {'items.*': 'distinct:ignore_case'},
      ).run()).keys.toSet(),
      {'items.0', 'items.1'},
    );
    // U+FB05 and U+FB06 are not paired in Unicode 15 (only from Unicode 16).
    expect(
      await Validator(
        {
          'items': ['\uFB05', '\uFB06'],
        },
        {'items.*': 'distinct:ignore_case'},
      ).run(),
      isEmpty,
    );
    // Cherokee U+13A0 / U+AB70 (paired in Unicode 14-15 C+S and PCRE2).
    expect(
      (await Validator(
        {
          'items': ['\u13A0', '\uAB70'],
        },
        {'items.*': 'distinct:ignore_case'},
      ).run()).keys.toSet(),
      {'items.0', 'items.1'},
    );
  });

  test(
    'ignore_case does not imitate PCRE \$ matching a trailing newline',
    () async {
      // PHP preg_grep('/^a$/iu', ['a\n']) matches because PCRE '$' matches
      // before a trailing newline; Daravel intentionally does not imitate this.
      final errors = await Validator(
        {
          'items': ['a', 'a\n'],
        },
        {'items.*': 'distinct:ignore_case'},
      ).run();
      expect(errors, isEmpty);
    },
  );

  test('caseFold matches every C+S rule in Unicode 15.0.0 CaseFolding.txt and '
      'ASCII 0..127 fast path agrees with the table', () {
    final file = File('../../tool/validation/CaseFolding-15.0.0.txt');
    expect(file.existsSync(), isTrue, reason: 'missing CaseFolding-15.0.0.txt');
    var rules = 0;
    for (final raw in file.readAsLinesSync()) {
      final line = raw.split('#').first.trim();
      if (line.isEmpty) {
        continue;
      }
      final parts = line.split(';').map((p) => p.trim()).toList();
      if (parts.length < 3 || (parts[1] != 'C' && parts[1] != 'S')) {
        continue;
      }
      rules++;
      final from = int.parse(parts[0], radix: 16);
      final to = int.parse(parts[2], radix: 16);
      expect(
        DistinctRule.caseFold(String.fromCharCode(from)),
        String.fromCharCode(to),
        reason: 'U+${parts[0]} -> U+${parts[2]}',
      );
    }
    expect(rules, 1454);
    expect(unicodeCaseFolding.length, 1454);

    // Every ASCII code point 0..127 matches the static table.
    for (var cp = 0; cp < 128; cp++) {
      final expected = unicodeCaseFolding[cp] ?? cp;
      expect(
        DistinctRule.caseFold(String.fromCharCode(cp)),
        String.fromCharCode(expected),
        reason: 'ASCII $cp',
      );
    }
  });

  test('work counters: plain distinct skips folding and identity; ignore_case '
      'folds each value at most once per run', () async {
    final items = [for (var i = 0; i < 100; i++) 'Item_$i'];

    DistinctRule.debugResetCounters();
    expect(
      await Validator({'items': items}, {'items.*': 'distinct'}).run(),
      isEmpty,
    );
    expect(DistinctRule.debugFoldCalls, 0);
    expect(DistinctRule.debugIdentityCalls, 0);

    DistinctRule.debugResetCounters();
    expect(
      await Validator({'items': items}, {'items.*': 'distinct:strict'}).run(),
      isEmpty,
    );
    expect(DistinctRule.debugFoldCalls, 0);
    expect(DistinctRule.debugIdentityCalls, 100);

    DistinctRule.debugResetCounters();
    expect(
      await Validator(
        {'items': items},
        {'items.*': 'distinct:ignore_case'},
      ).run(),
      isEmpty,
    );
    expect(DistinctRule.debugFoldCalls, 100);
    expect(DistinctRule.debugIdentityCalls, 0);
  });
}
