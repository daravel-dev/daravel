@Tags(['conformance'])
library;

import 'package:daravel/daravel.dart';
import 'package:daravel_test/conformance.dart';
import 'package:test/test.dart';

/// Keys of the data that hold a `.` or a `*` are keys, as in Laravel: a
/// failure under a wildcard is reported under the key as sent.
void main() {
  test('a failure under a wildcard keeps a dotted data key in its error '
      'key', () async {
    final validator = Validator(
      {
        'items': {
          'a.b': {'role': 'admin'},
        },
      },
      {'items.*.role': 'in:member'},
    );
    final errors = await validator.run();
    expect(errors.keys, [LaravelContract.dottedKeyErrorKey]);
  });

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
