import 'dart:convert';
import 'dart:io';

import 'package:daravel/daravel.dart';
import 'package:test/test.dart';

/// `same`, `different` (several fields) and `exclude_without` (several
/// fields) against Laravel itself: each case of
/// `fixtures/laravel_same_different.json` was run through
/// `Validator::make` in Laravel 13.40.0 / PHP 8.3 (the interop image,
/// without network); Daravel must report the same attributes with the same
/// messages.
void main() {
  final golden = jsonDecode(
    File('test/validation/fixtures/laravel_same_different.json')
        .readAsStringSync(),
  ) as Map<String, Object?>;
  final cases = (golden['cases']! as List<Object?>)
      .cast<Map<String, Object?>>();

  test('the golden is from Laravel 13', () {
    expect(golden['laravel'], startsWith('13.'));
    expect(cases, hasLength(greaterThan(20)));
  });

  for (final c in cases) {
    // PHP writes an empty array for `{}`.
    final data = switch (c['data']) {
      final Map<String, Object?> map => map,
      _ => <String, Object?>{},
    };
    final rules = (c['rules']! as Map<String, Object?>).cast<String, Object>();
    final expected = switch (c['errors']) {
      final Map<String, Object?> map => {
        for (final MapEntry(:key, :value) in map.entries)
          key: (value! as List<Object?>).cast<String>(),
      },
      _ => <String, List<String>>{},
    };
    test('$rules with $data', () async {
      expect(await Validator(data, rules).run(), expected);
    });
  }

  test('unique and exists refuse where conditions in the string form', () {
    for (final rule in [
      'unique:users,email,NULL,id,account_id,1',
      'exists:users,id,active,1',
    ]) {
      expect(
        () => Validator({}, {'x': rule}),
        throwsA(
          isA<ArgumentError>().having(
            (e) => '${e.message}',
            'message',
            contains('.where('),
          ),
        ),
        reason: rule,
      );
    }
    // The forms without conditions still parse.
    Validator({}, {'a': 'unique:users,email,NULL,id', 'b': 'exists:users,id'});
  });

  test('the typed forms take several fields', () async {
    final errors = await Validator(
      {'a': 'x', 'b': 'y', 'c': 'x'},
      {
        'a': Rules.differentFrom(['b', 'c']),
        'x': Rules.excludeWithoutAny(['b', 'z']).required(),
      },
    ).run();
    expect(errors.keys, ['a']);
    expect(() => Rules.differentFrom([]), throwsArgumentError);
    expect(() => Rules.excludeWithoutAny([]), throwsArgumentError);
  });
}
