@Tags(['conformance'])
library;

import 'package:daravel/daravel.dart';
import 'package:daravel_test/conformance.dart';
import 'package:test/test.dart';

/// An empty key of the data is a key, as in Laravel: `Arr::dot` writes it
/// as an empty segment and a rule's `*` matches it.
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
}
