import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:daravel/src/validation/case_folding.g.dart';
import 'package:daravel/src/validation/php_compare.dart';
import 'package:test/test.dart';

void main() {
  test(
    'distinct:ignore_case follows PCRE2 Unicode 14-15 (C+S) case folding',
    () async {
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
    },
  );

  test(
    'distinct:ignore_case does not imitate PCRE \$ matching a trailing newline',
    () async {
      expect(
        await Validator(
          {
            'items': ['a', 'a\n'],
          },
          {'items.*': 'distinct:ignore_case'},
        ).run(),
        isEmpty,
      );
    },
  );

  test('phpCaseFold matches every C+S rule in Unicode 15.0.0 CaseFolding.txt '
      'and ASCII 0..127 fast path agrees with the table', () {
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
        phpCaseFold(String.fromCharCode(from)),
        String.fromCharCode(to),
        reason: 'U+${parts[0]} -> U+${parts[2]}',
      );
    }
    expect(rules, 1454);
    expect(unicodeCaseFolding.length, 1454);

    for (var cp = 0; cp < 128; cp++) {
      final expected = unicodeCaseFolding[cp] ?? cp;
      expect(
        phpCaseFold(String.fromCharCode(cp)),
        String.fromCharCode(expected),
        reason: 'ASCII $cp',
      );
    }
  });

  test('work counters: lazy per-mode indexing; phpCaseFold and phpNumeric '
      'called at most once per item per run', () async {
    final items = [for (var i = 0; i < 100; i++) 'Item_$i'];

    PhpValueIndex.debugResetCounters();
    expect(
      await Validator({'items': items}, {'items.*': 'distinct'}).run(),
      isEmpty,
    );
    expect(PhpValueIndex.debugCaseFoldCalls, 0);
    expect(PhpValueIndex.debugNumericCalls, 100);

    PhpValueIndex.debugResetCounters();
    expect(
      await Validator({'items': items}, {'items.*': 'distinct:strict'}).run(),
      isEmpty,
    );
    expect(PhpValueIndex.debugCaseFoldCalls, 0);
    expect(PhpValueIndex.debugNumericCalls, 0);

    PhpValueIndex.debugResetCounters();
    expect(
      await Validator(
        {'items': items},
        {'items.*': 'distinct:ignore_case'},
      ).run(),
      isEmpty,
    );
    expect(PhpValueIndex.debugCaseFoldCalls, 100);
    expect(PhpValueIndex.debugNumericCalls, 0);
  });
}
