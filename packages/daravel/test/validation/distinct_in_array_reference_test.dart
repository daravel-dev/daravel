import 'dart:convert';
import 'dart:math';

import 'package:daravel/daravel.dart';
import 'package:daravel/src/validation/php_compare.dart';
import 'package:test/test.dart';

/// `distinct` and `in_array` against a reference written as Laravel 13
/// writes them (`validateDistinct`, `getDistinctValues`, `validateInArray`):
/// `Arr::dot` of the input, the keys matched by a regex, and each item
/// compared with every other one by PHP's `==` or `===`, or by a
/// case-insensitive regex for `ignore_case`. That scan is quadratic; the
/// rules count the values once per run, and must decide the same.
void main() {
  // Arr::dot: a non-empty list or map is walked, anything else (an empty
  // list or map too) is a leaf.
  Map<String, Object?> dot(Object? value, [String prefix = '']) {
    final entries = switch (value) {
      final List<Object?> list when list.isNotEmpty => [
        for (var i = 0; i < list.length; i++) MapEntry('$i', list[i]),
      ],
      final Map<String, Object?> map when map.isNotEmpty => map.entries,
      _ => null,
    };
    if (entries == null) {
      return {prefix: value};
    }
    return {
      for (final MapEntry(:key, :value) in entries)
        ...dot(value, prefix.isEmpty ? key : '$prefix.$key'),
    };
  }

  Map<String, Object?> leaves(
    Map<String, Object?> data,
    String pattern,
    String star,
  ) {
    final regex = RegExp(
      '^${pattern.split('*').map(RegExp.escape).join(star)}\$',
      dotAll: true,
    );
    return {
      for (final MapEntry(:key, :value) in dot(data).entries)
        if (regex.hasMatch(key)) key: value,
    };
  }

  // Null when Laravel throws: preg_grep over a list or map.
  bool? distinctFails(
    Map<String, Object?> data,
    String pattern,
    String attribute,
    Object? value,
    List<String> flags,
  ) {
    final others = leaves(data, pattern, '[^.]+')..remove(attribute);
    if (flags.contains('ignore_case') && value is String) {
      final regex = RegExp(
        '^${RegExp.escape(value)}\$',
        caseSensitive: false,
        unicode: true,
      );
      var found = false;
      for (final other in others.values) {
        final text = phpStringForm(other);
        if (text == null) {
          return null;
        }
        found |= regex.hasMatch(text);
      }
      return found;
    }
    return others.values.any(
      (other) => flags.contains('strict')
          ? phpIdentical(value, other)
          : phpLooseEquals(value, other),
    );
  }

  bool inArrayFails(Map<String, Object?> data, String other, Object? value) =>
      !leaves(data, other, '.*').values.any((v) => phpIdentical(value, v));

  // The attributes the validator checks: present, and not a blank string
  // (neither rule is implicit).
  bool checked(Map<String, Object?> data, String attribute) {
    if (!ValidationContext.exists(data, attribute)) {
      return false;
    }
    final value = ValidationContext.dig(data, attribute);
    return !(value is String && value.trim().isEmpty);
  }

  final values = <Object?>[
    0, 1, 2, -1, 0.0, -0.0, 1.0, 1.5, 0.1 + 0.2, 1e14, 1e-5, //
    '0', '1', '1.0', ' 1', '1e0', '.5', '0.3', '1.0E+14', '-0', '', //
    'a', 'A', 'é', 'É', 'ß', 'ẞ', 'SS', 's', 'S', 'ſ', 'k', 'K', 'K',
    'null', 'abc', 'ABC', true, false, null, <Object?>[],
    <Object?>[1], <String, Object?>{'a': 1}, <String, Object?>{'a': '1'},
  ];

  test('the same failures as the quadratic reference', () async {
    final random = Random(20261112);
    Object? value() => values[random.nextInt(values.length)];
    List<Object?> list(int max) => [
      for (var i = random.nextInt(max + 1); i > 0; i--) value(),
    ];
    var compared = 0;
    var failing = 0;
    for (var i = 0; i < 3000; i++) {
      final n = 1 + random.nextInt(6);
      final Map<String, Object?> data;
      final String pattern;
      switch (random.nextInt(4)) {
        case 0:
          data = {'items': list(6)};
          pattern = 'items.*';
        case 1:
          data = {
            'items': [
              for (var j = 0; j < n; j++)
                random.nextInt(6) == 0 ? <String, Object?>{} : {'id': value()},
            ],
          };
          pattern = 'items.*.id';
        case 2:
          data = {
            'items': [
              for (var j = 0; j < n; j++) {'tags': list(3)},
            ],
          };
          pattern = 'items.*.tags.*';
        default:
          // Maps with named keys at both levels.
          data = {
            'groups': {
              for (var j = 0; j < n; j++)
                'g$j': {
                  for (var k = random.nextInt(3); k >= 0; k--) 'v$k': value(),
                },
            },
          };
          pattern = 'groups.*.*';
      }
      final inArray = random.nextInt(4) == 0;
      final String rule;
      final Map<String, Object?> input;
      if (inArray) {
        rule = 'in_array:others.*';
        input = {...data, 'others': list(5)};
      } else {
        rule = [
          'distinct',
          'distinct:strict',
          'distinct:ignore_case',
          'distinct:strict,ignore_case',
        ][random.nextInt(4)];
        input = data;
      }
      final flags = rule.contains(':') && !inArray
          ? rule.split(':')[1].split(',')
          : const <String>[];
      final expected = <String>{};
      var throws = false;
      for (final attribute in Validator.expandPattern(input, pattern)) {
        if (!checked(input, attribute)) {
          continue;
        }
        final value = ValidationContext.dig(input, attribute);
        final fails = inArray
            ? inArrayFails(input, 'others.*', value)
            : distinctFails(input, pattern, attribute, value, flags);
        if (fails == null) {
          throws = true;
          break;
        }
        if (fails) {
          expected.add(attribute);
        }
      }
      if (throws) {
        continue;
      }
      final errors = await Validator(input, {pattern: rule}).run();
      expect(
        errors.keys.toSet(),
        expected,
        reason: '$rule ${jsonEncode(input)}',
      );
      compared++;
      if (expected.isNotEmpty) {
        failing++;
      }
    }
    expect(compared, greaterThan(2000));
    expect(failing, greaterThan(800));
  });
}
