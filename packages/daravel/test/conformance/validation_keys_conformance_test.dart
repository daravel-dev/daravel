@Tags(['conformance'])
library;

import 'package:daravel/daravel.dart';
import 'package:daravel_test/conformance.dart';
import 'package:test/test.dart';

/// An empty key of the data is a key, as in Laravel: `Arr::dot` writes it
/// as an empty segment, a rule's `*` matches it, and nothing under it
/// stands in for a named field.
void main() {
  test('a top-level wildcard matches an empty data key', () async {
    final validator = Validator(
      {
        '': {'role': 'admin'},
      },
      {'*.role': 'in:member'},
    );
    final errors = await validator.run();
    expect(errors.keys, [LaravelContract.emptyKeyErrorKey]);
  });

  test('a value under an empty key is not the named field for '
      'in_array', () async {
    expect(
      Validator.expandPattern({
        '': {
          'allowed': [
            {'code': 'ADMIN'},
          ],
        },
      }, '*.allowed.*.code'),
      [LaravelContract.emptyKeyDotPath],
    );
    final validator = Validator(
      {
        'allowed': [
          {'code': 'USER'},
        ],
        '': {
          'allowed': [
            {'code': 'ADMIN'},
          ],
        },
        'pick': 'ADMIN',
      },
      {'pick': 'in_array:allowed.*.code'},
    );
    expect((await validator.run()).keys, ['pick']);
  });
}
