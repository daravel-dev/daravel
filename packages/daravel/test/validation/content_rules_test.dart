import 'dart:convert';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

/// The content rules of laravel/framework 13.x `ValidatesAttributes` that
/// Daravel lacked before W9.4a: `contains`, `doesnt_contain`,
/// `doesnt_start_with`, `doesnt_end_with`, `in_array`, `in_array_keys`,
/// `array_keys`, `hex_color`, `mac_address`, `encoding`, `base64`. Messages
/// are Laravel 13's `lang/en/validation.php` with its `ReplacesAttributes`
/// placeholders.
void main() {
  Future<Map<String, List<String>>> errors(
    Map<String, Object?> data,
    Map<String, Object> rules,
  ) => Validator(data, rules).run();

  Future<bool> ok(Object? value, String rule) async =>
      (await errors({'a': value}, {'a': rule})).isEmpty;

  test('contains: every value, compared loosely', () async {
    expect(await ok(['x', 'y', 1], 'contains:x,1'), isTrue);
    expect(await ok(['x'], 'contains:x,y'), isFalse);
    expect(await ok({'k': 'x'}, 'contains:x'), isTrue);
    expect(await ok('x', 'contains:x'), isFalse);
    expect(await errors({'a': <Object>[]}, {'a': 'contains:x'}), {
      'a': ['The a field is missing a required value.'],
    });
  });

  test('doesnt_contain: none of the values, compared strictly', () async {
    expect(await ok(['x'], 'doesnt_contain:y'), isTrue);
    expect(await ok(['x'], 'doesnt_contain:x,y'), isFalse);
    expect(await ok([1], 'doesnt_contain:1'), isTrue, reason: 'int 1 !== "1"');
    expect(
      await errors(
        {
          'a': ['x'],
        },
        {'a': 'doesnt_contain:x,y'},
      ),
      {
        'a': ['The a field must not contain any of the following: x, y.'],
      },
    );
  });

  test('doesnt_start_with and doesnt_end_with', () async {
    expect(await ok('admin-ana', 'doesnt_start_with:admin,root'), isFalse);
    expect(await ok('ana', 'doesnt_start_with:admin,root'), isTrue);
    expect(await ok(1234, 'doesnt_start_with:12'), isFalse);
    expect(await ok(['x'], 'doesnt_start_with:a'), isFalse);
    expect(await ok('file.exe', 'doesnt_end_with:.exe'), isFalse);
    expect(await errors({'a': 'x.exe'}, {'a': 'doesnt_end_with:.exe,.bat'}), {
      'a': ['The a field must not end with one of the following: .exe, .bat.'],
    });
    expect(await errors({'a': 'rootx'}, {'a': 'doesnt_start_with:root'}), {
      'a': ['The a field must not start with one of the following: root.'],
    });
  });

  test('in_array: one of the values at a wildcard path, strictly', () async {
    final data = {
      'choice': 2,
      'options': [
        {'id': 1},
        {'id': 2},
      ],
    };
    expect(await errors(data, {'choice': 'in_array:options.*.id'}), isEmpty);
    expect(
      await errors(
        {...data, 'choice': '2'},
        {'choice': 'in_array:options.*.id'},
      ),
      {
        'choice': ['The choice field must exist in options.*.id.'],
      },
    );
  });

  test('in_array_keys and array_keys', () async {
    expect(await ok({'en': 'x'}, 'in_array_keys:en,id'), isTrue);
    expect(await ok({'fr': 'x'}, 'in_array_keys:en,id'), isFalse);
    expect(await ok('x', 'in_array_keys:en'), isFalse);
    expect(await ok({'en': 1, 'id': 2}, 'array_keys:en,id'), isTrue);
    expect(await ok({'en': 1, 'fr': 2}, 'array_keys:en,id'), isFalse);
    expect(await ok(['a'], 'array_keys:0'), isTrue);
    expect(
      await errors(
        {
          'a': {'fr': 1},
        },
        {'a': 'in_array_keys:en,id'},
      ),
      {
        'a': [
          'The a field must contain at least one of the following keys: en, id.',
        ],
      },
    );
    expect(
      await errors(
        {
          'a': {'fr': 1},
        },
        {'a': 'array_keys:en,id'},
      ),
      {
        'a': ['The a field must only contain the following keys: en, id.'],
      },
    );
  });

  test('hex_color', () async {
    for (final v in ['#fff', '#FFFA', '#a1b2c3', '#a1b2c3d4']) {
      expect(await ok(v, 'hex_color'), isTrue, reason: v);
    }
    for (final v in ['fff', '#ff', '#fffff', '#ggg', 123]) {
      expect(await ok(v, 'hex_color'), isFalse, reason: '$v');
    }
    expect(await errors({'a': 'red'}, {'a': 'hex_color'}), {
      'a': ['The a field must be a valid hexadecimal color.'],
    });
  });

  test('mac_address, as FILTER_VALIDATE_MAC', () async {
    for (final v in [
      '01:23:45:67:89:ab',
      '01-23-45-67-89-AB',
      '0123.4567.89ab',
    ]) {
      expect(await ok(v, 'mac_address'), isTrue, reason: v);
    }
    for (final v in ['01:23:45-67:89:ab', '0123456789ab', '01:23:45:67:89']) {
      expect(await ok(v, 'mac_address'), isFalse, reason: v);
    }
    expect(await errors({'a': 'x'}, {'a': 'mac_address'}), {
      'a': ['The a field must be a valid MAC address.'],
    });
  });

  test('encoding', () async {
    expect(await ok('héllo', 'encoding:UTF-8'), isTrue);
    expect(await ok('héllo', 'encoding:ASCII'), isFalse);
    expect(await ok('héllo', 'encoding:ISO-8859-1'), isTrue);
    // mb_check_encoding looks at bytes, and every byte sequence is valid
    // ISO-8859-1: any string passes in Laravel, the euro sign included.
    expect(await ok('\u{1F600} €', 'encoding:ISO-8859-1'), isTrue);
    expect(await ok(String.fromCharCode(0xD800), 'encoding:UTF-8'), isFalse);
    expect(await errors({'a': 'é'}, {'a': 'encoding:ASCII'}), {
      'a': ['The a field must be encoded in ASCII.'],
    });
    // Not an encoding: Laravel's InvalidArgumentException.
    expect(
      () => errors({'a': 'x'}, {'a': 'encoding:KLINGON'}),
      throwsA(isA<ArgumentError>()),
    );
    // Valid in Laravel (mb_list_encodings), not checked by Daravel yet.
    expect(
      () => errors({'a': 'x'}, {'a': 'encoding:UTF-16'}),
      throwsA(
        isA<UnsupportedError>().having(
          (e) => e.message,
          'message',
          contains('supported: UTF-8, ASCII, ISO-8859-1'),
        ),
      ),
    );
  });

  test('doesnt_start_with on a whole float reads it as PHP does', () async {
    // JSON 1.0 arrives as the double 1.0; (string) 1.0 is "1" in PHP.
    expect(await ok(1.0, 'doesnt_start_with:1.'), isTrue);
    expect(await ok(1.0, 'doesnt_end_with:1'), isFalse);
    expect(await ok(1.5, 'doesnt_end_with:.5'), isFalse);
  });

  test('base64: canonical standard Base64 only', () async {
    expect(await ok(base64Encode(utf8.encode('hello')), 'base64'), isTrue);
    for (final v in ['aGVsbG8', 'aGVs bG8=', 'aGV-bG8=', 123]) {
      expect(await ok(v, 'base64'), isFalse, reason: '$v');
    }
    expect(await errors({'a': '%%%'}, {'a': 'base64'}), {
      'a': ['The a field must be a valid Base64 string.'],
    });
  });

  test('every builder parses back from its string and chains', () {
    final pairs = <String, Rule>{
      'contains:x': Rules.contains(['x']),
      'doesnt_contain:x': Rules.doesntContain(['x']),
      'doesnt_start_with:x': Rules.doesntStartWith(['x']),
      'doesnt_end_with:x': Rules.doesntEndWith(['x']),
      'in_array:items.*': Rules.inArray('items.*'),
      'in_array_keys:x': Rules.inArrayKeys(['x']),
      'array_keys:x': Rules.arrayKeys(['x']),
      'hex_color': Rules.hexColor(),
      'mac_address': Rules.macAddress(),
      'encoding:UTF-8': Rules.encoding('UTF-8'),
      'base64': Rules.base64(),
    };
    for (final MapEntry(key: dsl, value: rule) in pairs.entries) {
      final parsed = RuleParser.parseOne(dsl);
      expect(parsed.name, rule.name, reason: dsl);
      expect(parsed.runtimeType, rule.runtimeType, reason: dsl);
    }
    expect(
      Rules.required()
          .hexColor()
          .doesntStartWith(['#000'])
          .toList()
          .map((r) => r.name),
      ['required', 'hex_color', 'doesnt_start_with'],
    );
  });
}
